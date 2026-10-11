# Tiptap Draft editor evaluation

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/draft-editor-evaluation.md).

[#818](https://github.com/unwired-dev/product/issues/818) asks whether a locally
packaged [Tiptap](https://tiptap.dev) editor can open, edit, save and reopen a Draft
on iPhone, iPad and the AppKit Mac host. This is a feasibility evaluation. The
[current composer](drafts.md) stays the default and the comparison baseline;
nothing here replaces it. Formatting fidelity ([#819](https://github.com/unwired-dev/product/issues/819)),
Inline Images ([#820](https://github.com/unwired-dev/product/issues/820)), save
ordering across the bridge ([#821](https://github.com/unwired-dev/product/issues/821)),
usability and performance ([#822](https://github.com/unwired-dev/product/issues/822))
and the adoption decision ([#823](https://github.com/unwired-dev/product/issues/823))
are separate evaluations.

## Selecting the evaluation editor

Only builds of the `registration-draft-editor`
[Mock Mail Session](mock-mail-sessions.md) contain the evaluation editor page. Those
builds sign into a synthetic Product Account with a synthetic Gmail mailbox and
real encrypted storage, so the editor never sees a person's Drafts. Every other
build, including production and TestFlight, excludes the editor page and opens
Drafts in the current composer.

## Behavior

In an evaluation build, **New Message** and Draft rows open the **Evaluation editor**
in place of the composer, in the same place on each host. It shows **Close**, the
sending mailbox, the save status and the body. The body edits plain paragraphs:
typing, Return for a new paragraph and deletion. Tiptap's own Undo history is
active in the page, but Undo and Redo controls and their native qualification
belong to #819 and #822. Recipients, subject, formatting, files and Send stay with
the current composer.

- **Saving.** Every change is saved through the Draft store, as in the current
  composer, and the status shows **Saved on this device**, **Saving…**, or why the
  latest edit is not saved. Locked storage and failed saves keep the edit in memory.
- **Close.** Saves and closes once the Draft is stored. When saving fails the editor
  stays open with **Try again**. Closing an empty Draft discards it.
- **Leaving.** Opening **Account**, another Draft, **New Message** or received mail
  first saves the Draft, as the current composer does.
- **Unsupported bodies.** A Draft with formatting, other block kinds or Inline Images
  is not opened. The editor says it opens plain paragraphs only and leaves the Draft
  unchanged.
- **Failures.** If the page stops, the editor says so; saved changes are kept. Callbacks from a closed editor cannot submit further edits.
- **Account.** Drafts belong to the signed-in Product Account. Locked or unavailable
  Draft storage shows the current composer's **Drafts are locked** and **Try again**.

## Isolation

The editor must load its code and styles locally, refuse networking and navigation,
and use a non-persistent, cache-free WebKit data store. No cloud collaboration,
vendor AI, remote asset service, browser persistence or paid editor service is enabled.
Only the opened body crosses into the page; encryption keys, account identifiers
and other Drafts stay outside it. The host validates page messages before saving.
Malformed messages and callbacks from a closed editor change nothing.

Drafts keep the Semantic Message Document as their durable contract. Tiptap JSON,
HTML and Markdown are never stored. The object replacement character that marks
an Inline Image is removed from typed or pasted text.

The hosts' native renderer bundles must contain no React DOM, Tiptap or ProseMirror
modules. `verify:bundle` checks that boundary and rejects an editor page in any
scenario other than `registration-draft-editor`.

## Evaluated packages

Pinned exactly in the root `pnpm-workspace.yaml` catalog, referenced by
`packages/draft-editor/package.json`, and resolved in the lockfile. No paid
service or license key is required. MIT requires keeping the copyright and
license notices with distributed copies; evaluation builds are test builds and are
not distributed.

| Package                                                                                             | Version | License | Use                    |
| --------------------------------------------------------------------------------------------------- | ------- | ------- | ---------------------- |
| `@tiptap/core`                                                                                      | 3.31.4  | MIT     | Editor                 |
| `@tiptap/pm`                                                                                        | 3.31.4  | MIT     | ProseMirror re-exports |
| `@tiptap/extension-document`, `@tiptap/extension-paragraph`, `@tiptap/extension-text`               | 3.31.4  | MIT     | Plain-paragraph schema |
| `@tiptap/extensions`                                                                                | 3.31.4  | MIT     | Undo and Redo          |
| `prosemirror-model`, `-state`, `-view`, `-transform`, `-history`, `-keymap`, `-commands` and others | 1.x–2.x | MIT     | Through `@tiptap/pm`   |
| `esbuild`                                                                                           | 0.28.2  | MIT     | Builds the page        |
| `happy-dom`                                                                                         | 20.14.5 | MIT     | Page tests in Vitest   |

The packaged page is about 309 KB, including Tiptap, ProseMirror and the bridge.

**TenTap was not used.** The evaluated host adapter is the existing patched
`react-native-webview` 13.16.1 on both hosts.

**Native adapter work.** None beyond allowing the new scenario in the synthetic
registration provider. The existing WebView, its patch, the Draft store and the
native encrypted Draft storage are used unchanged.

## Run the evaluation

Build the selected scenario and run the native runner as for any
[Mock Mail Session](mock-mail-sessions.md):

```sh
UNWIRED_MOCK_SCENARIO=registration-draft-editor mise exec -- pnpm --filter @private-email/mobile native:generate --no-install
cd apps/mobile/ios && mise exec -- pod install && cd ../../..
xcodebuild build -workspace apps/mobile/ios/UnwiredMail.xcworkspace \
  -scheme UnwiredMail -configuration Release -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath artifacts/mock-mail/DerivedData \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- ARCHS=arm64
mise exec -- pnpm --filter @private-email/mobile test:native \
  "$PWD/artifacts/mock-mail/DerivedData/Build/Products/Release-iphonesimulator/UnwiredMail.app"

UNWIRED_MOCK_SCENARIO=registration-draft-editor \
mise exec -- pnpm --filter @private-email/macos native:build Testing
UNWIRED_SIGNING_IDENTITY='Apple Development' \
UNWIRED_MOCK_PROFILE='/absolute/path/to/mock-only.provisionprofile' \
mise exec -- pnpm --filter @private-email/macos test:native \
  "$PWD/artifacts/macos-inbox/DerivedData/Build/Products/Testing/UnwiredMail.app"
```

Metro builds the page when it loads its configuration for this scenario. Each
journey signs in, starts **New Message**, types a paragraph into the page, waits for
**Saved on this device**, rotates the device (iPhone, iPad) or narrows the window
(Mac), closes the Draft, relaunches and reopens it. The mobile journey attaches screenshots to the
XCTest results; the Mac journey records its assertions when signing permits execution.

Shared and component checks:

```sh
mise exec -- pnpm --filter @private-email/draft-editor test
mise exec -- pnpm --filter @private-email/mobile test -- evaluation-composer
mise exec -- pnpm --filter @private-email/macos test -- evaluation-composer
UNWIRED_MOCK_SCENARIO=registration-draft-editor mise exec -- pnpm verify:bundle
```

## Evidence

Page tests run the real Tiptap editor, the conversion boundary and the bridge in
Vitest's `happy-dom`: an edit reaches the host as a Semantic Message Document with
empty paragraphs and Unicode preserved, and Undo restores the stored body. They also
check the page's Content Security Policy. Component journeys on both hosts send page
messages through the real Draft store with synthetic storage: they save, show and
recover a locked save, refuse a malformed message, close, reopen the stored body
through a fresh store, and leave a formatted Draft unchanged. These are not native
evidence.

Native execution on 2026-10-11, Apple M4 Mac mini, macOS 27.0.1, Xcode 27.0
(27A266a), iOS 27.0 Simulator runtime (24A434), Release build with Hermes,
`react-native` 0.86.3 and `react-native-webview` 13.16.1 (patched). The corrected
Release app was rebuilt after the resolver refactor and callback-lifetime fixes.
Both fresh task-owned simulator journeys passed (`Executed 1 test, with 0 failures`
on each host); their logs, screenshots and XCTest result bundles are in
`artifacts/expo-bootstrap/native-h5cLr5/`, with the build log in
`artifacts/mock-mail-818/review-build.log`.

The first reviewer run (`artifacts/expo-bootstrap/native-beFsZg/`) failed before
opening the editor: rapid Recovery Key confirmation input lost characters in the
controlled field. The new journeys now wait for each character to appear before
sending the next one. The subsequent full iPhone and iPad journeys passed. Earlier
implementer runs also passed but preceded the final corrections and are historical
evidence (`artifacts/expo-bootstrap/native-1Ak7aW/`).

| Host                            | Open, type, save, close, relaunch, reopen | Focus                                                                  | Resize                                                         | Teardown                                                     |
| ------------------------------- | ----------------------------------------- | ---------------------------------------------------------------------- | -------------------------------------------------------------- | ------------------------------------------------------------ |
| iPhone 18 Pro Simulator         | Passed with the encrypted Draft store     | Tapping the body showed the software keyboard; typing reached the page | Landscape rotation kept the page and its text without a reload | Close removed the web view; relaunch reopened the saved body |
| iPad Pro 11-inch (M5) Simulator | Passed with the encrypted Draft store     | Typing reached the page beside the Inbox column                        | Landscape rotation kept the page and its text without a reload | Close removed the web view; relaunch reopened the saved body |
| Mac (AppKit)                    | Outstanding                               | Outstanding                                                            | Outstanding                                                    | Outstanding                                                  |

On the Mac, the corrected `registration-draft-editor` `Testing` build
(`react-native-macos` 0.81.9, `react-native-webview` 13.16.1) succeeded with the
scenario marker and the packaged page in its bundle
(`artifacts/mock-mail-818/review-mac-build-retry.log`), and the corrected journey's
XCTest source type-checks. The first review build stopped during CocoaPods setup
with `pathname contains null byte`; the infrastructure retry built successfully. The
journey was not run: this host has no `Apple Development` identity or mock
provisioning profile, and an ad-hoc Mac app cannot open the Data Protection
Keychain, so its encrypted Draft storage would be unavailable.

Outstanding before any adoption decision: the Mac native journey with a signed
mock profile; physical iPhone and iPad runs; hardware keyboards, IME, dictation,
autocorrection and VoiceOver ([#822](https://github.com/unwired-dev/product/issues/822));
inspection of website data after teardown and account removal
([#820](https://github.com/unwired-dev/product/issues/820)); and save ordering under
delayed page messages ([#821](https://github.com/unwired-dev/product/issues/821)).
Simulator runs do not qualify devices.

## Finding

**Proceed** to the dependent evaluations (#819–#822) on iPhone and iPad. A
locally packaged Tiptap page edited, saved and reopened a Draft through the existing
encrypted Draft store on iPhone and iPad simulators, with networking refused, no
renderer dependency on React DOM, and no native adapter beyond the existing WebView.
No fundamental host failure was found there.

The Mac remains **unproven**, not failed: its build and bundle checks pass, but
its native journey needs a signed mock profile. Run it before Mac-dependent
evaluation work treats the Mac host as feasible. This finding is not an adoption
recommendation; that is #823.
