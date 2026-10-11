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

In an evaluation build, **New Message**, Draft rows and **Reply** open the
**Evaluation editor** in place of the composer, in the same place on each host. It
shows **Close**, the sending mailbox, the save status, the
[formatting toolbar](#formatting-and-history) and the body. Recipients, subject,
quoted correspondence, files and Send stay with the current composer; no edit in the
page changes them.

- **Saving.** Every change is saved through the Draft store, as in the current
  composer, and the status shows **Saved on this device**, **Saving…**, or why the
  latest edit is not saved. Locked storage and failed saves keep the edit in memory.
- **Close.** Saves and closes once the Draft is stored. When saving fails the editor
  stays open with **Try again**. Closing an empty Draft discards it.
- **Leaving.** Opening **Account**, another Draft, **New Message** or received mail
  first saves the Draft, as the current composer does.
- **Unsupported bodies.** A Draft with an Inline Image is not opened until
  [#820](https://github.com/unwired-dev/product/issues/820). The editor says so and
  leaves the Draft unchanged.
- **Failures.** If the page stops, the editor says so, clears assistance previews and
  keeps saved changes. Callbacks from a stopped or closed page cannot submit edits
  or accept results. Close the Draft and reopen it to resume editing.
- **Account.** Drafts belong to the signed-in Product Account. Locked or unavailable
  Draft storage shows the current composer's **Drafts are locked** and **Try again**.

## Formatting and history

The body edits the current [Semantic Message Document](drafts.md#composing):
paragraphs, headings one to three, bulleted and numbered lists, quotes and code
blocks, with bold, italic, underline, strikethrough and inline code. Its rules are
the current composer's:

- **Toolbar.** **Undo**, **Redo**, the five marks and the seven block kinds, then
  **Translate**, **Rewrite** and **Suggest reply** while
  [Mail Assistance Enablement](message-summaries.md#mail-assistance-enablement) is on.
  The toolbar appears once the page reports that it has loaded, so no command or
  accepted result can reach a page that cannot apply it. Each press is one command
  to the page. A mark applies to the selection, or to the
  next typed text at the caret until the caret moves. A block kind applies to every
  selected block, and returns them to paragraphs when they all have it. The page
  reports the marks and block kind at the selection, which the toolbar shows as
  selected.
- **Markdown shortcuts.** `# `, `## `, `### `, `- `, `* `, `1. `, `> ` and three
  backticks at the start of a paragraph apply that block kind and remove the marker;
  one **Undo** restores the literal marker. Return continues a list, quote or code
  block; deleting into a list marker turns the item into a paragraph. Inline Markdown
  such as `**bold**` is not a shortcut, as in the current composer.
- **Undo and Redo.** One step per activation, a word of typing at a time; a space
  and every other edit are steps of their own. Repeated commands before the host
  redraws each advance the history. Command-Z and Shift-Command-Z on Mac, and the
  page's other Tiptap keyboard shortcuts, act in the page.
- **Assistance.** [Draft rewrites, reply suggestions](draft-assistance.md) and
  [Draft translation](message-translation.md) capture the selection or body the page
  last reported, through the same capture rules and review panels as the current
  composer. On iPhone and iPad, choosing one ends editing in the page so the software
  keyboard does not cover the review panel; the selection is kept. An accepted
  result replaces exactly the captured text in the page as
  one edit that one **Undo** reverts and **Redo** restores; surrounding formatting is
  kept. A result for an earlier body revision is never applied: any edit retires the
  capture, and the page refuses a replacement computed from another revision.
- **Paste.** Pasted HTML keeps only supported meaning: headings one to three,
  paragraphs, lists, quotes, code and the five marks. Smaller headings, tables and
  styled text become paragraphs; a heading or code inside a quote or list item
  becomes that quote line or item; nested lists become items of their own; a pasted
  numbered list counts from one; links keep their text without the destination;
  images, styles, colors and sizes are dropped; and multi-line code becomes one code
  line per line. Plain text becomes one paragraph per line. Nothing else reaches
  the stored document.

### Semantic mismatches

The current Semantic Message Document cannot store link destinations, so this
editor offers no link authoring and pasted links retain only their text.
[#878](https://github.com/unwired-dev/product/issues/878) owns link support for both
composers and blocks the adoption decision in #823.

Return in code always starts another code line; use **Code block** to return the
selected lines to paragraphs. Extra Tiptap keyboard shortcuts, such as Command-E
for inline code and Command-Option-1 for a heading, also work in the page.

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
| `@tiptap/extension-document`, `@tiptap/extension-paragraph`, `@tiptap/extension-text`               | 3.31.4  | MIT     | Document schema        |
| `@tiptap/extension-heading`, `-list`, `-blockquote`                                                 | 3.31.4  | MIT     | Block kinds            |
| `@tiptap/extension-bold`, `-italic`, `-underline`, `-strike`, `-code`                               | 3.31.4  | MIT     | Marks                  |
| `@tiptap/extensions`                                                                                | 3.31.4  | MIT     | Undo and Redo          |
| `prosemirror-model`, `-state`, `-view`, `-transform`, `-history`, `-keymap`, `-commands` and others | 1.x–2.x | MIT     | Through `@tiptap/pm`   |
| `esbuild`                                                                                           | 0.28.2  | MIT     | Builds the page        |
| `happy-dom`                                                                                         | 20.14.5 | MIT     | Page tests in Vitest   |

The packaged page is about 351 KB, including Tiptap, ProseMirror and the bridge
(309 KB with plain paragraphs only).

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
journey signs in, turns on on-device assistance (this build's model and Translation
are synthetic), starts **New Message**, types a paragraph into the page, waits for
**Saved on this device**, rotates the device (iPhone, iPad) or narrows the window
(Mac), then formats the paragraph and steps **Undo** and **Redo**. It relaunches and
reopens this formatted Draft, checks bold and numbered-list selection state, then
accepts selected-text and whole-body rewrites, selected-text translation, and a
reply suggestion. Each operation checks the complete visible authored text after
one **Undo** and **Redo**, and relaunches to reopen both its undone and accepted
states. The Mac journey also uses Command-B, Command-Z and Shift-Command-Z. The
mobile journey attaches screenshots to the XCTest results; the Mac journey records
its assertions when signing permits execution.

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

The merge with Microsoft mail was checked again on the same date for PR #861,
review round 7. The first iPhone run could not type after tapping the blank center
of the empty editor (`artifacts/expo-bootstrap/native-rS07Qy/`). Focusing the first
paragraph passed on iPhone; the next iPad run missed Close immediately after
returning to portrait (`artifacts/expo-bootstrap/native-4EcpYd/`). The journey now
focuses the first paragraph and waits for the portrait editor width before Close.
Both final packaged journeys passed with zero failures
(`artifacts/expo-bootstrap/native-wcrkAl/`), including encrypted saving and reopening.
The final app build log is `artifacts/review-634-r7/native-build-final.log`.

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

For that merge review, the Mac XCTest source type-checked and both production and
evaluation bundle checks passed. A fresh native build could not start: CocoaPods
failed with `pathname contains null byte` on both setup attempts
(`artifacts/review-634-r7/mac-pods.log` and `artifacts/review-634-r7/mac-pods-retry.log`). The
host still has no development signing identity, so the signed Mac journey remains
outstanding.

### Formatting fidelity (#819)

Page tests run the real Tiptap configuration in `happy-dom`. They round-trip every
ordered pair of block kinds, empty and with mixed marks and Unicode, through open,
edit and post; match every textblock's display offsets to the current composer's,
including list markers and numbering; apply marks to selections and to the next typed
text; set and clear block kinds; apply each Markdown shortcut and restore its literal
marker with one Undo; step Undo and Redo a word at a time, once per command; continue
lists, quotes and code with Return; enforce the paste policy; and apply a revision-
guarded replacement as one undoable edit. Component journeys on both hosts drive the
toolbar, rewrite, reply suggestion and translation through the Draft store and the
page bridge with the synthetic assistance and translation providers, and retire a
capture when the body changes.

The reply component journeys also populate To, Cc, Bcc, subject, quoted
correspondence and reply threading, accept the page's body update, close and load a
fresh Draft store, and compare the saved Draft with those fields unchanged. Their
storage boundary is substituted; they do not inspect those hidden fields in the
native evaluation UI.

Native execution on 2026-10-11, same host and toolchain as above, Release build with
Hermes: the iPhone 18 Pro and iPad Pro 11-inch (M5) simulator journeys passed
(`Executed 1 test, with 0 failures` on each) in fresh task-owned simulators, with
screenshots and result bundles in `artifacts/expo-bootstrap/native-db9UIL/`. Each
journey turned on on-device assistance, typed and rotated, made the paragraph bold
and a numbered list, stepped **Undo** and **Redo**, then relaunched and reopened the
Draft with its marks and block kind shown as selected. For a rewrite of a selection,
a rewrite of the whole body, a German translation of a selection and a reply
suggestion in a **Reply** Draft, it accepted the result, reverted it with one **Undo**,
and relaunched and reopened the undone body; then it accepted the result again,
reverted and restored it with one **Undo** and **Redo**, and relaunched and reopened
the accepted body. Each reopened body matched the page's text before closing. The
model and Translation results are this build's synthetic ones; they show the bridge
and the edit, not Apple's models.

The second review added expected result text and explicit Bold and numbered-list
state assertions after each assistance Apply, Undo, Redo and reopening, including
the non-list Reply body. The final source passed on fresh iPhone 18 Pro and iPad Pro
11-inch (M5) simulators with the same Release/Hermes app (`Executed 1 test, with 0
failures` and zero skips on each): `artifacts/expo-bootstrap/native-o61Jt7/`. The
first revised run failed while reopening: the editor was visible but its WebKit page
was not ready, and the retry tapped an Inbox row that was no longer visible. The
retry now taps only while the editor is absent, using the existing wait budget; the
subsequent full run passed. The failed run is retained in
`artifacts/expo-bootstrap/native-pcgL4O/` and does not qualify the journey.

Earlier runs of the journey found two defects that are now fixed: the review panel
sat under the software keyboard on iPhone, and a result accepted before the page had
loaded was dropped. Other earlier runs failed on test synchronization (taps during
layout or list changes after launch, selections and Draft-row targeting, since
corrected in the journey), on host load (load average up to about 200 from other
jobs) and once on a reboot; those runs are in `artifacts/expo-bootstrap/native-*` and
are not evidence.

The earlier Mac `Testing` build succeeded with the page in its bundle. The updated
journey (both rewrite scopes, translation, reply suggestions, and undone/accepted
reopening) type-checks; it was not run, for the signing reason above.

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

**#819 finding.** The current block kinds and marks pass the page and host checks
above. Link editing remains deferred to #878, Mac native formatting remains
unproven, and iPhone/iPad simulator text, history and the exercised post-assistance
formatting assertions have passing evidence. This does not approve adoption; #823
owns that decision.
