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
evaluation editor in place of the composer, in the same place on each host. It uses
the [approved compose design](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=279-19140)
([iPad](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=295-50811),
[Mac](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=297-46535)): the
current composer's header with **Close**, the title and **Send**; the sending
mailbox; the page's body; the Draft's [files and Inline Images](#files-and-inline-images);
and then **Subject**, **To**, and **Cc** and **Bcc** once shown. Quoted
correspondence stays as the Draft has it; no edit in the page changes it. The
regular composer adopts the same design in
[#991](https://github.com/unwired-dev/product/issues/991).

On iPad, **From** sits beside **Send**. They wrap together below the title,
command input and expand control when the reading pane is narrow.

Save and Send feedback, errors and assistance reviews scroll with the body, files
and fields, so they can scroll away in a short window or above the keyboard.

- **Saving.** Nothing is saved while editing, and no save status is shown. The
  Draft is stored only when the person chooses **Save Draft** (**Save** on Mac) or
  **Send**, as in Mail.
- **Close.** An unchanged Draft closes at once, and an empty one is removed. Otherwise
  **Delete Draft** and **Save Draft** grow out of **Close** on iPhone and iPad, and the
  Mac asks **Do you want to save this message as a draft?** with **Save**,
  **Don’t Save** and **Cancel**. The Mac question pauses body editing, keeps keyboard
  focus within its choices and hides background composer controls from VoiceOver
  until a choice is made. When storage refuses, the editor stays open with
  **Try again**, and its edits still ask on the next **Close**. Unfinished recipient
  text becomes recipients on **Save Draft**; an invalid address keeps the editor open.
- **Send.** Stores the Draft as shown and queues it, then closes. A refusal, such as
  no recipients, keeps the editor open with its reason; the Draft stays stored.
- **Leaving.** Opening **Account**, another Draft, **New Message** or received mail
  asks the same question first; it leaves once the Draft is saved, deleted or
  unchanged.
- **Removal elsewhere.** A Draft deleted on another device while open keeps this
  editor's version; **Save Draft** stores it as a conflicting copy.
- **Finishing.** Close, Save Draft and Send finish queued body edits before inspecting
  the Draft. Editing pauses while saving or sending, and resumes if the operation
  cannot finish. A pending navigation continues after the chosen save or deletion.
- **Failures.** If the page stops, the editor says so and clears assistance previews.
  Callbacks from a stopped or closed page cannot submit edits or accept results.
  **Save Draft** still stores the body the page last reported; reopen the Draft to
  resume editing.
- **Account.** Drafts belong to the signed-in Product Account. Locked or unavailable
  Draft storage shows the current composer's **Drafts are locked** and **Try again**.

## Formatting and history

The body edits the current [Semantic Message Document](drafts.md#composing):
paragraphs, headings one to three, bulleted and numbered lists, quotes and code
blocks, with bold, italic, underline, strikethrough and inline code. Its rules are
the current composer's:

- **Controls.** On iPad and Mac the current composer's format bar: the text style
  menu, the four marks, lists, **Undo** and **Redo**, **Writing tools** and the file
  controls. On iPhone a floating Liquid Glass pill with **Format** and **Add files**,
  and a separate **Writing tools** button, sit above the keyboard. **Format** replaces
  the keyboard with the Format panel: **Undo**, **Redo**, the three headings and
  **Body**, the five marks, lists, quote and code block; closing it, or tapping into the
  body, brings the keyboard back. **Writing tools** lists today's **Rewrite**,
  **Translate** and **Suggest reply** while
  [Mail Assistance Enablement](message-summaries.md#mail-assistance-enablement) or
  translation is available. The controls appear once the page reports that it has
  loaded, so no command or accepted result can reach a page that cannot apply it.
  Each press is one command to the page. A mark applies to the selection, or to the
  next typed text at the caret until the caret moves. A block kind applies to every
  selected block, and returns them to paragraphs when they all have it. The page
  reports the marks and block kind at the selection, which the toolbar shows as
  selected.
- **Markdown shortcuts.** `# `, `## `, `### `, `- `, `* `, `1. `, `> ` and three
  backticks at the start of a paragraph apply that block kind and remove the marker;
  one **Undo** restores the literal marker. Return continues a list, quote or code
  block, including an empty list item or quote line; deleting into a list marker turns
  the item into a paragraph. Inline Markdown
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

## Files and Inline Images

[#820](https://github.com/unwired-dev/product/issues/820) opens Drafts with files and
Inline Images. The page shows Inline Images in the body. Under the body, the editor
lists the Draft's Attachments and Inline Images with the current composer's rows:
name, size or state, **Cancel** while adding, **Try again** when a check can run
again, and **Remove**.

- **Adding.** **Attach File**, **Attach Photo**, **Insert Image** and **Paste Image**
  (in the **Add files** menu on iPhone, on the format bar on iPad), and
  **Attach Files…** and **Insert Image…** on Mac, use the
  current composer's system pickers and native import. Images placed inline go at
  the page's selection, replacing any selected text; other files become Attachments.
  Each pick is one edit in the page.
- **Pasting and dropping.** On iPhone and iPad, pasting images into the page imports
  them from the pasteboard through native code, as **Paste Image** does. The page
  never reads pasted or dropped file data: on Mac a paste carrying images adds
  nothing, and files dropped on the page are refused on every host. Text and
  supported formatting paste as before. A copied or cut Inline Image pastes back
  within the page with the same asset; other pasted images are dropped.
- **Editing.** An Inline Image is one character of the text, as in the current
  composer. Typing around it, deleting it, moving it by cut and paste or by dragging,
  **Undo** and **Redo** keep its Draft Asset.
- **Converting.** The row's context menu (long press on iPhone and iPad, secondary
  click on Mac) and its VoiceOver action offer **Attach Instead**, which turns an
  Inline Image into an Attachment, removing each place it appears, or **Show Inline**,
  which places an image Attachment at the page's selection, beside **Remove**. Each is one edit that one **Undo** reverts and **Redo** restores.
  The current composer does not offer conversion yet.
- **Imports.** While native code imports a file, its row shows **Adding…**. Editing
  continues, and an import that completes meanwhile neither loses the edit nor
  creates a conflicting copy. A cancelled, failed or interrupted import stays listed
  as not added. An import still running when **Save Draft** closes the editor
  completes into the stored Draft. While the editor is open, **Undo** can restore any asset the page was
  given, with its stored bytes.
- **Pictures.** Native code checks an image's bytes against its digest and returns a
  thumbnail at most 256 pixels on its longest side. Only that thumbnail reaches the
  page, which shows a dashed placeholder until then and for damaged, missing or
  locked bytes; the rows say why, as in the current composer.
- **Identity.** The page names images and Attachments by asset identifier. The host
  accepts only assets it gave the page, keeps their latest native state, and saves
  the Semantic Message Document with them. A thumbnail never becomes part of the
  Draft.

Quoted correspondence and its images stay as the Draft has them.

## Isolation

The editor must load its code and styles locally, refuse networking and navigation,
and use a non-persistent, cache-free WebKit data store. No cloud collaboration,
vendor AI, remote asset service, browser persistence or paid editor service is enabled.
Only the opened body, the names and types of its files, and thumbnails of verified
image bytes cross into the page; file bytes, encryption keys, account identifiers
and other Drafts stay outside it. The page's Content Security Policy admits only
`data:` images. The host validates page messages before saving. Malformed messages,
assets the host never gave the page, and callbacks from a closed editor change
nothing.

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
are synthetic), starts **New Message**, types a paragraph into the page, rotates the
device (iPhone, iPad) or narrows the window (Mac), then formats the paragraph (in the
Format panel on iPhone) and steps **Undo** and **Redo**. It chooses **Save Draft** on
**Close**, relaunches and reopens this formatted Draft, checks bold and numbered-list selection state, then
accepts selected-text and whole-body rewrites, selected-text translation, and a
reply suggestion. Each operation checks the complete visible authored text after
one **Undo** and **Redo**, and relaunches to reopen both its undone and accepted
states. The Mac journey also uses Command-B, Command-Z and Shift-Command-Z. The
iPhone and iPad journey then starts another **New Message**, types, places a photo
with **Insert Image** from the system Photos picker, types after it, turns it into an
Attachment with **Attach Instead** from the row's context menu and back with
**Show Inline**, steps **Undo** and **Redo** across the last conversion, then saves
and relaunches and reopens the Draft with the image and its thumbnail in place. The
runner adds `native-tests/photo.png` to each fresh Simulator's photo library for it. The mobile journey
attaches screenshots to the XCTest results; the Mac journey records its assertions
when signing permits execution.

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
the Inline Image checks [below](#inline-images-820) leaves outstanding; and save
ordering under delayed page messages ([#821](https://github.com/unwired-dev/product/issues/821)).
Simulator runs do not qualify devices.

### Inline Images (#820)

Page tests run the real Tiptap configuration in `happy-dom`. An Inline Image keeps its
Draft Asset through typing, deletion, Undo and Redo, and through a cut and paste
within the page; it counts as one display offset. A pasted image the page was never
given, and any other pasted image, are dropped. Adding images and Attachments,
removing them and converting in both directions are each one edit that one Undo
reverts and Redo restores. The page shows only the thumbnails the host sends, also on
an image Undo recreates. A paste carrying files is refused unread and asks the host to
read the pasteboard; a drop carrying files is refused; moving content within the page
is unaffected. The Content Security Policy admits only `data:` images.

Component journeys on both hosts pick files through the synthetic native pickers and
import them through the real Draft store with synthetic storage. They check that one
pick sends one page edit, that an import completing while the page keeps typing
neither loses the edit nor creates a conflicting copy, and that the page's older copy
of an asset cannot undo its completion. They also check the thumbnail sent after the
bytes verify, Attachments, conversion and removal, that an asset the page was never
given is not saved, and that reopening gives the page the same asset identities.
Cancelling an import, an import completing after **Close** into the stored Draft, and
damaged bytes listed as damaged with no thumbnail sent are covered too. On iPhone and
iPad a paste request from the page runs the native pasteboard import; on Mac it adds
nothing. The saved body uses the same Inline Image spans as the current composer, so
the existing outgoing-format boundary applies unchanged; this evaluation sends nothing.
These are not native evidence.

Component journeys also cover the composer layout: nothing is stored until **Save
Draft**; a refused save keeps the editor open with **Try again** and still asks on the
next **Close**; an unchanged Draft closes and an empty one is removed without asking;
**Delete Draft** removes the Draft; a refused **Send** stays open with its reason and
stores the shown version; the iPhone Format panel, its keyboard hand-off and Writing
tools; the iPad format bar; and the conversion menu and its accessibility action.

Native execution on 2026-10-15, same Mac mini and toolchain as above (macOS 27.0.1,
Xcode 27.0, iOS 27.0 Simulator runtime), with a Release `registration-draft-editor`
build with Hermes of the final layout. The iPhone 18 Pro journey passed (`Executed 1
test, with 0 failures`) in `artifacts/expo-bootstrap/native-L6ZWPp/`, after an earlier
pass in `artifacts/expo-bootstrap/native-ggmWHA/`, and the iPad Pro 11-inch (M5)
journey passed in `artifacts/expo-bootstrap/native-yE3fOx/`. On iPhone it typed and
rotated in the composer layout, formatted from the Format panel, ran every #819
rewrite, translation and reply round trip from **Writing tools**, chose **Save Draft**
on each **Close** before relaunching, and closed unchanged Drafts without a prompt.
It then placed a photo with **Insert Image** from **Add files**, showed its native
thumbnail, chose **Attach Instead** and **Show Inline** from the row's context menu,
stepped **Undo** and **Redo**, saved, relaunched and reopened the Draft with the image
and thumbnail in place. The iPad journey ran the same steps from the format bar, its
**Writing tools** menu and its file controls. Screenshots are in the result bundles.
Earlier attempts on the same day found and corrected defects: rotation squeezed the
body before it scrolled, the iPhone pill sat behind the keyboard, and the iPad format
bar's scrolling clipped the **Writing tools** menu; others failed in the journey's own
steps or, on iPad, before the editor opened under a load average of about 900 from
other jobs. Those runs are in `artifacts/expo-bootstrap/native-*` and are not evidence.

Before reaching the new steps, the journey needed repairs for changes since #819:
the Gmail registration heading now reads **Gmail connected**, **Account** is in the
Mailboxes column, and **Reply** opens a menu of responses. Earlier failed runs in
`artifacts/expo-bootstrap/native-*` are not evidence. A first attempt placed an
image from the Simulator pasteboard with **Paste Image**; a pasteboard written by the
XCUITest runner reached the app empty, with no paste prompt, so the journey uses the
Photos picker instead.

During the runs, a watcher sampled the app's data container on each Simulator every
five seconds for WebKit website data (local storage, IndexedDB, cache storage,
cookies and other WebKit stores). No sample found any, through typing, imports,
**Save Draft**, relaunch and reopening, on iPhone and on iPad.

Outstanding for #820: the Mac native journey, which needs a signed mock profile;
pasting image data into the page on Mac, and dropping files on the page on every
host, which need native interception in the web view (the page refuses both unread);
**Paste Image** and in-page paste on a device; website data after account removal,
which this journey does not exercise; a network capture of the journey beyond the
page's refusal of networking and navigation; and physical iPhone and iPad runs.

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

**#820 finding.** Inline Images and Attachments keep their Draft Asset identity
through page editing, conversion, Undo, Redo, saving and reopening on iPhone and iPad
simulators, and the page receives only native thumbnails. Image paste and drop into
the page need native web-view work before they match the current composer on Mac,
and drops on every host. The current composer does not offer conversion yet. This
does not approve adoption; #823 owns that decision.
