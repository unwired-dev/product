# Native Mac mock Inbox

`apps/macos` implements [#593](https://github.com/unwired-dev/product/issues/593)
with AppKit windows and React Native macOS views. It reads the same synthetic,
in-memory mailbox as Expo through `@private-email/mail-core`. It has no provider,
credentials, persistence, sending, or Convex connection.

## Host ownership

The `macos` catalog pins React Native macOS 0.81.9, React Native 0.81.6 and React
19.1.4 in the root workspace and lockfile. This follows the amended
[ADR 0064](adr/0064-isolate-mobile-and-macos-native-dependencies.md), which
supersedes the issue's original separate-lockfile requirement. Mac views and
native adapters live in `apps/macos`; `mail-core` imports no UI framework.

The entry point loads the approved `fast-text-encoding@1.0.6` polyfill before
Effect. Mac Hermes lacks `TextEncoder` and `TextDecoder`; the polyfill supplies
UTF-8 encoding only, not a general message-charset decoder.

Metro redirects React and React Native imports, including subpaths, to this
host's packages. Its startup module also comes from React Native macOS. The
production source-map check rejects the mobile renderer, Expo, React DOM and
backend code, checks the shared fixture against disk, and verifies native
autolinking. The host currently autolinks no additional native modules. Adding
one requires an explicit update to that check.

AppKit owns stable window identities and menu routing. One React factory and one
JavaScript mailbox runtime live for the application process. Each window mounts
its own React root and owns its selected message. Closing a window releases its
view; opening another starts with no selection. Reading leaves mock unread flags
unchanged.

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
pnpm on `PATH` for Xcode build phases. `RUBY` selects the test runner's Ruby.

```sh
mise exec -- pnpm install --frozen-lockfile --strict-peer-dependencies
cd apps/macos
mise exec -- pnpm native:build
open ../../artifacts/macos-inbox/DerivedData/Build/Products/Release/UnwiredMail.app
```

The checked-in Objective-C++ host, Podfile and Ruby project generator own the
native setup. `native:build` regenerates the ignored Xcode project, installs Pods
using the committed `Podfile.lock`, and builds arm64 with isolated DerivedData.
Local builds use ad-hoc signing and
disable hardened runtime because ad-hoc dynamic frameworks have no Team ID. The
generated project retains hardened runtime for distribution signing. All
configurations target macOS 27. Release embeds `main.jsbundle`; it never falls
back to Metro. The native build phase exports and verifies the bundle before
copying it into the app. Distribution signing and App Store archives remain
unqualified.

For development, run `pnpm dev`, then build the generated `UnwiredMail` scheme in
Debug. Debug uses Metro. Regenerate the native project and reinstall Pods after
changing native setup or dependencies.

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

Two component integration scenarios exercise independent selections, closing one
view while another remains, and selecting mail after every view unmounts. They
run the real shared mock service with React Native's test renderer. They do not
prove AppKit lifecycle behavior.

For the native journey, build the optimized, packaged `Testing` configuration:

```sh
cd apps/macos
mise exec -- pnpm native:build Testing
mise exec -- pnpm test:native ../../artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app
```

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
private storage, delivery, accessibility and distribution still require their own
checks. No legacy coverage is retired by this slice.
