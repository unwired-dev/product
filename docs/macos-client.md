# Native Mac client and mock Inbox

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/macos-client.md).

`apps/macos` implements [#593](https://github.com/unwired-dev/product/issues/593)
with AppKit windows and React Native macOS views. It reads the same synthetic
mailbox as Expo through `@private-email/mail-core`, with
[native encrypted read-state persistence](private-inbox-storage.md). Production
registration now creates a Convex Product Account and authorizes Gmail through
the native adapter. Mail synchronization and sending are later slices.

Production launches offer [Apple](apple-registration.md) or [Google](google-registration.md)
registration with separate Gmail consent. Either can later be [linked](linked-sign-in.md)
as the other sign-in method. A new account [initializes private Product Sync](private-product-sync.md):
the device that wins initialization presents the Recovery Key, and a competing device
enters enrollment. Configure the native client ID and Convex deployment when generating the host.
Select an explicit Mock Mail Session to run the synthetic Inbox journeys.

## Window behavior

The `macos` catalog pins React Native macOS 0.81.9, React Native 0.81.6 and React
19.1.4 in the root workspace and lockfile. Keep React and native imports out of
`mail-core`. Mac views and native adapters live in `apps/macos`.

Load the approved `fast-text-encoding@1.0.6` polyfill in the entry point before
Effect. Mac Hermes lacks `TextEncoder` and `TextDecoder`; the polyfill supplies
UTF-8 encoding only, not a general message-charset decoder.

The production source-map check rejects the mobile renderer, Expo, React DOM and
backend code, checks the shared fixture against disk, and verifies native
autolinking. The host currently autolinks no additional native modules. Adding
one requires an explicit update to that check.

Each window owns its selected message. Opening another starts with no selection.
Reading leaves unread flags unchanged. Explicit read/unread actions persist and
update all windows without changing their selections.

| Command                                | Behavior                                            |
| -------------------------------------- | --------------------------------------------------- |
| File > New Window, Command-N           | Open an independent Inbox                           |
| File > Close Window, Command-W         | Close the focused window                            |
| Window > Show Inbox, Command-0         | Focus the first Inbox, or create one if none remain |
| Window > Next Window, Command-backtick | Cycle through Inbox windows                         |
| Window > Inbox number                  | Focus that window                                   |
| Dock/Finder reopen                     | Focus an existing Inbox or create one               |
| Unwired Mail > Quit, Command-Q         | End the process                                     |

Closing the final window keeps the application and its runtime alive. Explicit
Quit stops application work; there is no separate helper. This slice establishes
the host lifecycle, not real synchronization or queued delivery.

Native menus use AppKit accessibility. Message buttons expose labels and selected
state, support keyboard focus, and show a focus border. Full VoiceOver and
hardware-keyboard qualification remain separate release checks.

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
Local builds default to ad-hoc signing and
disable hardened runtime because ad-hoc dynamic frameworks have no Team ID. The
generated project retains hardened runtime for distribution signing.
Google and Apple sign-in, and persistence, require the
[Keychain signing setup](private-inbox-storage.md#native-wiring-and-signing).
Google's SDK reports `com.google.GIDSignIn` code `-2` when it cannot store
credentials in Keychain; ad-hoc builds report locked storage. All
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
developer-portal resources. Debug uses Metro. Quit and reopen the app after a
native rebuild. Regenerate the native project and reinstall Pods after changing
native setup or dependencies.

## Verification

```sh
mise exec -- pnpm --filter @private-email/macos lint
mise exec -- pnpm --filter @private-email/macos format
mise exec -- pnpm --filter @private-email/macos check-types
mise exec -- pnpm --filter @private-email/macos test
mise exec -- pnpm --filter @private-email/macos build
mise exec -- pnpm --filter @private-email/macos verify:bundle
```

The [Mac CI workflow](../.github/workflows/macos.yml) runs Fallow and the production
bundle/autolinking check. The root TypeScript job runs Mac lint, format, types and
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
`UNWIRED_SIGNING_IDENTITY` and `UNWIRED_MOCK_PROFILE`. It signs an external cleanup
helper for the same isolated Keychain group. The ordinary preview app and its
store are preserved. Without that profile, record native execution as deferred;
component, bundle and runner contracts remain available.

The XCTest journey opens two windows, selects different messages, focuses a
window through its menu, closes both, checks continued application work, reopens
through Launch Services, reads another message, and chooses the native Quit menu.
Command-Q is checked separately through direct native UI automation because
XCTest key injection after reopening is unreliable on the qualification host.
The journey checks one process
and session throughout. It requires a logged-in macOS 27 desktop with XCTest UI
automation permission. The runner uses its own probe project and result directory
and rejects zero-test success. XCTest terminates its launched app on failure.

Only `Testing` compiles the synthetic application-scoped work timer and JSONL
probe. The test creates a temporary output file and supplies `UNWIRED_LIFECYCLE_PATH`;
the application never creates a test-control server or accepts reset commands.
Records contain only lifecycle event names, process/session identity, window
counts and tick counts. Release compiles out the probe and timer. Ordinary local
OS logs contain lifecycle names and window counts, never message content.

The lifecycle JSONL is an XCTest attachment; the test deletes its temporary file.
Results live in `artifacts/macos-inbox/journey.*`. Capture visual evidence
separately through native UI automation; XCTest window screenshots fail on the
qualification host’s multi-display setup. Preserve native,
component and bundle evidence as distinct claims in the
[qualification record](qualification/expo-react-native-client.md). Real Gmail,
delivery, accessibility and distribution still require their own checks.
[Private storage](private-inbox-storage.md) has separate real integration checks. No legacy coverage is retired by this slice.
