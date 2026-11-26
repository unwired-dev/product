# Tiptap Draft editor evaluation

Setup, coding rules, validation and observable requirements remain in this file.
Architecture notes live in the separate [architecture companion](architecture/draft-editor-evaluation.md).

[#818](https://github.com/unwired-dev/product/issues/818) asks whether a locally
packaged [Tiptap](https://tiptap.dev) editor can open, edit, save and reopen a Draft
on iPhone, iPad and the AppKit Mac host. This is a feasibility evaluation. The
[current composer](drafts.md) stays the default and the comparison baseline;
nothing here replaces it. Formatting fidelity ([#819](https://github.com/unwired-dev/product/issues/819)),
Inline Images ([#820](https://github.com/unwired-dev/product/issues/820)), save
ordering across the bridge ([#821](https://github.com/unwired-dev/product/issues/821)),
usability and performance ([#822](https://github.com/unwired-dev/product/issues/822))
and the adoption decision ([#823](https://github.com/unwired-dev/product/issues/823))
are separate evaluations. [ADR 0080](adr/0080-edit-the-draft-body-in-the-tiptap-page.md) records the adoption and its rollout gates.

The [confirmed launch requirements](product/power-user-launch.md#confirmed-scope-additions-from-2026-10-24)
require lossless editing of provider-hosted Drafts. This evaluation's bounded
formatting and lossy paste behavior do not satisfy that target, and its existing
evidence does not qualify provider Draft interoperability. Production lossless
editing is tracked in [rich formatting #1267](https://github.com/unwired-dev/product/issues/1267)
and [tables #1268](https://github.com/unwired-dev/product/issues/1268). Those
tickets do not establish adoption of this evaluation editor or completion of
its separate evaluation work.

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
On iPhone, the floating menus remain interactive when a short landscape viewport
places them over the header. Closing panels fade away with the shared menu motion;
their controls stop accepting input and leave VoiceOver immediately.

- **Saving.** Nothing is saved while editing, and no save status is shown. The
  Draft is stored only when the person chooses **Save Draft** (**Save** on Mac) or
  **Send**, as in Mail.
- **Close.** An unchanged Draft closes at once, and an empty one is removed. Otherwise
  **Delete Draft** and **Save Draft** grow out of **Close** on iPhone and iPad, and the
  Mac asks **Do you want to save this message as a draft?** with **Save**,
  **Don’t Save** and **Cancel**. The Mac question is a system alert sheet on the
  editor's own window: AppKit keeps keyboard focus and VoiceOver in it, Escape chooses
  **Cancel**, and body editing pauses until a choice is made. A question whose editor
  goes away, as when another Product Account opens, closes without an answer.
  When storage refuses, the editor stays open with
  **Try Again**, and its edits still ask on the next **Close**. Unfinished recipient
  text becomes recipients on **Save Draft**; an invalid address keeps the editor open.
- **Send.** Stores the Draft as shown and queues it, then closes. A refusal, such as
  no recipients, keeps the editor open with its reason; the Draft stays stored.
- **Leaving.** Opening another Draft, **New Message** or received mail
  asks the same question first; it leaves once the Draft is saved, deleted or
  unchanged. On Mac, Command-W, the window's close button and Quit ask too, and the
  window closes after **Save** or **Don’t Save**. Quit continues through any other
  open editors and then stops the app; **Cancel** or a failed finish cancels Quit.
  **Account** follows the separate [Settings navigation contract](gmail-inbox.md#settings).
- **Removal elsewhere.** A Draft deleted on another device or in another window while
  open keeps this editor's version and its attachment and image bytes; **Save Draft**
  stores it as a conflicting copy.
- **Two windows.** When two Mac windows edit one Draft and one saves first, **Save**
  in the other keeps its version as a conflicting copy. That window stays on the
  copy with the same page and Undo history, even when storage refuses the save, and
  its later edits, **Save** and **Don’t Save** change only the copy.
- **Finishing.** Close, Save Draft and Send finish queued body edits before inspecting
  the Draft. Editing pauses while saving or sending, and resumes if the operation
  cannot finish. Queued formatting, history and file actions cannot change the
  paused page. A pending navigation continues after the chosen save or deletion.
  A deletion already in progress still removes this editor's conflicting copy if
  its window closes before storage finishes.
- **Ordering.** The page numbers its body edits. The editor keeps the newest body it
  has received and ignores a late report of an earlier edit, also while Close,
  Save Draft or Send waits for the page.
- **Durability.** Edits reach the Drafts only when **Save Draft** or **Send** stores
  them, and reopening shows the stored version. The editor also journals them, about
  2 seconds after an edit, to a device-local composer recovery record, which the next
  launch offers to restore in the page (ADR 0077; Mac #2933, iPhone and iPad #2944).
- **Failures.** If the page stops, the editor says so and clears assistance previews.
  Callbacks from a stopped or closed page cannot submit edits or accept results.
  **Save Draft** still stores the body the page last reported; reopen the Draft to
  resume editing.
- **Account.** Drafts belong to the signed-in Product Account. Locked or unavailable
  Draft storage shows the current composer's **Drafts are locked** and **Try Again**.
  When another Product Account opens while the editor is open, **Save Draft** closes
  it without storing its version in either account.

## Formatting and history

The body edits the current [Semantic Message Document](drafts.md#composing):
paragraphs, headings one to three, bulleted and numbered lists, quotes and code
blocks, with bold, italic, underline, strikethrough and inline code. Its rules are
the current composer's:

- **Stored formatting.** A Draft's alignment, list levels, text colors,
  backgrounds, font families and sizes open in the page and save back unchanged
  ([#2884](https://github.com/unwired-dev/product/issues/2884)). The page shows
  them as the current composer does, Dark colors included: a nested item sits one
  level further in, numbered items count per level and an aligned item's marker
  moves with its text. Typing, Return, joined blocks, marks and block kinds,
  from the Format controls or their shortcuts, keep them as
  [Drafts](drafts.md#composing) describes: typed text takes the format of the
  text before it, or at a block's start the text after it, even at a link's
  start, where it stays unlinked; typing, deleting, cutting or pasting over a
  selection, or adding an image there, Select All included, keeps the first
  selected block's kind, alignment and list level, even across a quote or list,
  as do Backspace and Delete across a block's edge; and joining an empty block
  with the next line keeps the empty block's. Pasted text carries no alignment
  or list level, while a drag within the page moves content as it is, also into
  an empty line. The page sets none of them.

- **Controls.** On iPad and Mac the current composer's format bar: the text style
  menu, the four marks, lists, the Link control, **Undo** and **Redo**, **Writing
  tools** and the file controls. On iPhone a floating Liquid Glass pill with
  **Format** and **Add files**, and a separate **Writing tools** button, sit above
  the keyboard. **Format** replaces the keyboard with the Format panel: **Undo**,
  **Redo**, the three headings and **Body**, the five marks, the Link control, lists,
  quote and code block; closing it, or tapping into the body, brings the keyboard
  back. **Writing tools** lists today's **Rewrite**,
  **Translate** and **Suggest Reply** while
  [Mail Assistance Enablement](message-summaries.md#mail-assistance-enablement) or
  translation is available. The controls appear once the page reports that it has
  loaded, so no command or accepted result can reach a page that cannot apply it.
  Each press is one command to the page. A mark applies to the selection, or to the
  next typed text at the caret until the caret moves. A block kind applies to every
  selected block, and returns them to paragraphs when they all have it. The page
  reports the marks at the selection and the block kind of its first block, Select
  All included, which the toolbar shows as selected.
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
- **Slash Command Menu.** On iPhone and iPad a `/` typed first in a body block
  opens the current composer's [Slash Command Menu](drafts.md#composing)
  ([#2952](https://github.com/unwired-dev/product/issues/2952)) with the same rows,
  less **Generate a Draft…**: the host reads the query from the body and selection
  the page reports, and the page reports where the caret's line is, so the menu
  hangs under it, or over it without room. While it shows, the page hands Return,
  Tab, Up Arrow, Down Arrow and Escape to the host instead of editing. A Basic
  Block removes the query and sets the block as one edit that one **Undo**
  reverts; an Insert command removes the query and opens its picker, and a Writing
  tool removes it and runs as from the format bar, once the page reports that its
  replacement made the edit, so a removal the page refused as stale runs neither.
  Moving the caret or leaving the body closes the menu, and an Undo or Redo that
  restores a `/` does not open it. The Mac page has none, as the Mac composer has none yet.
- **Paste.** Pasted HTML keeps only supported meaning: headings one to three,
  paragraphs, lists, quotes, code and the five marks. Smaller headings, tables and
  styled text become paragraphs; a heading or code inside a quote or list item
  becomes that quote line or item; nested lists become items of their own; a pasted
  numbered list counts from one; a link keeps its destination only when the Draft
  admits it as written (a web, mail or telephone address), and otherwise keeps only
  its text, so one **Undo** removes a pasted link with the rest of the paste;
  images, except an Inline Image copied or cut within the page, styles, colors,
  fonts, sizes, alignment and list levels are dropped, also when copied within
  the page; and multi-line code becomes one code
  line per line. Plain text becomes one paragraph per line. Nothing else reaches
  the stored document.
- **Tables.** The page edits a Draft's tables
  ([#2858](https://github.com/unwired-dev/product/issues/2858)) as the
  [table-editing plan](architecture/draft-table-editing.md#approved-behaviour)
  describes, with `prosemirror-tables` from `@tiptap/pm`; the hosts give the page
  the Draft's text without its tables until
  [#2865](https://github.com/unwired-dev/product/issues/2865). The caret's cell
  has a 2 pt `accent/fill` outline. Tab moves to the next cell and selects its
  text; Shift-Tab moves back and stays in the first cell. Tab in the last cell
  moves to the text after the table, adding a paragraph when the table ends the
  body, and never adds a row. Return adds a line in the cell, and marks and block
  kinds apply there. Backspace after a table selects it, and a second deletes it as
  one Undo step. A table scrolls sideways inside its own frame, and its cells do
  not wrap. The page edits a table whose rows fill the same columns with no
  overlapping merged cell and none reaching past the last row, the shapes
  `prosemirror-tables` keeps; it shows any other table with its text and keeps it
  unchanged, selectable and deletable but not editable. A cell never holds a table
  or an Inline Image: a paste keeps a pasted table's text, as anywhere else, an
  image pasted or converted into a cell is refused, and images added there become
  Attachments. No control builds a table.

### Semantic mismatches

The page keeps a Draft's links through editing, saving and reopening, and shows
linked text in the link color; it never opens a link, because the host refuses
every navigation. Text typed inside a link joins it, and text typed at either
edge, including after Return splits it, stays unlinked. Replacing selected text
keeps the first replaced character's link. As in the current composer, the Link
control is **Edit Link**, opening the Link Editor for the link at the caret or
selection, or **Add Link** for selected unlinked text in one block without a line
break or an image: Text holds the selection, Link starts empty and focused, and
there is no **Remove Link**; on iPhone the editor is titled **Add Link**. It is
unavailable anywhere else. **Apply** and **Remove Link** each reach the page as one
replacement of the body revision it reported, so each is one **Undo** step and a
page that has moved on refuses it. A link or selection that the page has moved or
changed since the editor opened stays as it is. On iPhone the Format panel stays
open while the Link Editor is shown.

Return in code always starts another code line; use **Code Block** to return the
selected lines to paragraphs. Extra Tiptap keyboard shortcuts, such as Command-E
for inline code and Command-Option-1 for a heading, also work in the page.

## Files and Inline Images

[#820](https://github.com/unwired-dev/product/issues/820) opens Drafts with files and
Inline Images. The page shows Inline Images in the body. Under the body, the editor
lists the Draft's Attachments and Inline Images with the current composer's rows:
name, size or state, **Cancel** while adding, **Try Again** when a check can run
again, and **Remove**.

- **Adding.** **Attach File**, **Attach Photo**, **Insert Image** and **Paste Image**
  (in the **Add files** menu on iPhone, on the format bar on iPad), and
  **Attach Files…** and **Insert Image…** on Mac, use the
  current composer's system pickers and native import. Images placed inline go at
  the page's selection, replacing any selected text; other files become Attachments.
  Each pick is one edit in the page.
- **Pasting and dropping.** Pasting images into the page imports them from the
  pasteboard through native code: on iPhone and iPad as **Paste Image** does, and on
  Mac as the current composer's body pastes, so pasted image data goes inline and a
  pasted file goes inline when it is an image and otherwise becomes an Attachment
  ([#2929](https://github.com/unwired-dev/product/issues/2929)). The page never reads
  pasted or dropped file data, and files dropped on the page are refused on every
  host. A paste that
  carries an image beside text is treated as an image paste, so its text is not
  pasted; paste the text separately. Text and supported formatting without images
  paste as before. A copied or cut Inline Image pastes back
  within the page with the same asset; other pasted images are dropped.
- **Editing.** An Inline Image is one character of the text, as in the current
  composer. Typing around it, deleting it, moving it by cut and paste or by dragging,
  **Undo** and **Redo** keep its Draft Asset.
- **Converting.** The row's context menu (long press on iPhone and iPad, secondary
  click on Mac) and its VoiceOver action offer **Attach Instead**, which turns an
  Inline Image into an Attachment, removing each place it appears, or **Show Inline**,
  which places an image Attachment at the page's selection, beside **Remove**. Each is one edit that one **Undo** reverts and **Redo** restores.
  The current composer does not offer conversion yet.
- **Sizes.** An Inline Image's row menu and VoiceOver actions also offer the
  current composer's [display sizes](drafts.md#files-and-images), in an
  **Image Size** submenu on the Mac, each running the page's `resize` command,
  and its **Remove** reads **Remove Image**. The page still shows every image at its thumbnail size.
- **Imports.** While native code imports a file, its row shows **Adding…**. Editing
  continues, and an import that completes meanwhile neither loses the edit nor
  creates a conflicting copy. A cancelled, failed or interrupted import stays listed
  as not added. An import still running when **Save Draft** closes the editor
  completes into the stored Draft. While the editor is open, **Undo** can restore any asset the page was
  given, with its stored bytes.
- **Pictures.** Native code checks an image's bytes against its digest and returns a
  thumbnail at most 256 pixels on its longest side. Only that thumbnail reaches the
  page, which shows a dashed placeholder until then and for damaged, missing or
  locked bytes; the rows say why, as in the current composer. A previously shown thumbnail is removed when a later check finds its bytes
  unavailable, including after converting an Attachment back to an Inline
  Image; a successful retry restores it.
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
| `@tiptap/core`                                                                                      | 3.34.0  | MIT     | Editor                 |
| `@tiptap/pm`                                                                                        | 3.34.0  | MIT     | ProseMirror re-exports |
| `@tiptap/extension-document`, `@tiptap/extension-paragraph`, `@tiptap/extension-text`               | 3.34.0  | MIT     | Document schema        |
| `@tiptap/extension-heading`, `-list`, `-blockquote`                                                 | 3.34.0  | MIT     | Block kinds            |
| `@tiptap/extension-bold`, `-italic`, `-underline`, `-strike`, `-code`                               | 3.34.0  | MIT     | Marks                  |
| `@tiptap/extensions`                                                                                | 3.34.0  | MIT     | Undo and Redo          |
| `prosemirror-model`, `-state`, `-view`, `-transform`, `-history`, `-keymap`, `-commands` and others | 1.x–2.x | MIT     | Through `@tiptap/pm`   |
| `esbuild`                                                                                           | 0.28.2  | MIT     | Builds the page        |
| `happy-dom`                                                                                         | 21.0.4  | MIT     | Page tests in Vitest   |

The packaged page is about 351 KB, including Tiptap, ProseMirror and the bridge
(309 KB with plain paragraphs only).

**TenTap was not used.** The evaluated host adapter is the existing patched
`react-native-webview` 14.0.1 on both hosts.

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
device (iPhone, iPad) or narrows the window (Mac). On iPhone and iPad it then opens a
whole-body rewrite in landscape and rotates back; on iPad that review expands the
composer over the window, and the journey chooses **Collapse** first. Each journey then
formats the paragraph (in the Format panel on iPhone) and steps **Undo** and **Redo**.
It chooses **Save Draft** on
**Close**, relaunches and reopens this formatted Draft, checks bold and numbered-list selection state, then
accepts selected-text and whole-body rewrites, selected-text translation, and a
reply suggestion. Each operation checks the complete visible authored text after
one **Undo** and **Redo**, and relaunches to reopen both its undone and accepted
states. After the translation, the iPhone and iPad journey selects the paragraph and
links it with **Add Link** (from the Format panel on iPhone), checks that **Edit Link**
offers **Remove Link** and the destination, steps one **Undo**, which removes the
link and keeps the text so the control reads **Add Link** again, and **Redo**, then
relaunches and reopens the linked Draft, whose **Edit Link** shows the destination
([#2866](https://github.com/unwired-dev/product/issues/2866)). The Mac journey takes
the same step after its translation, selecting the paragraph with Command-Up Arrow
and Shift-Command-Down Arrow and choosing **Save** before the relaunch
([#2876](https://github.com/unwired-dev/product/issues/2876)). The Mac journey also
uses Command-B, Command-Z and Shift-Command-Z. The
iPhone and iPad journey then starts another **New Message**, types, places a photo
with **Insert Image** from the system Photos picker, types after it, turns it into an
Attachment with **Attach Instead** from the row's context menu and back with
**Show Inline**, steps **Undo** and **Redo** across the last conversion, then saves
and relaunches and reopens the Draft with the image and its thumbnail in place. The
runner adds `native-tests/photo.png` to each fresh Simulator's photo library for it. The mobile journey
attaches screenshots to the XCTest results; the Mac journey attaches its **Edit Link**
captures.

Shared and component checks:

```sh
mise exec -- pnpm --filter @private-email/draft-editor test
mise exec -- pnpm --filter @private-email/mobile test -- evaluation-composer evaluation-ordering evaluation-lifecycle
mise exec -- pnpm --filter @private-email/macos test -- evaluation-composer evaluation-ordering evaluation-lifecycle
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
| Mac (AppKit)                    | Passed on 2026-11-25 (#2876)              | Clicking the body focused the page; typing reached it                  | A narrower window kept the page and its text without a reload  | Close removed the web view; relaunch reopened the saved body |

The Mac row is from the first Mac run, on 2026-11-25, recorded below. Until
then, the history below applied. On the Mac, the corrected `registration-draft-editor` `Testing` build
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

Rerun on 2026-11-13 for [#989](https://github.com/unwired-dev/product/issues/989), Apple
M4 Mac mini, macOS 27.2 (26B123), Xcode 27.2 (27B52), iOS 27.0 Simulator runtime
(24A434), Release `registration-draft-editor` build of `91362c12f`, Dark appearance.
The iPad Pro 11-inch (M5) journey failed after the landscape rewrite: since #2052 a
text tool's review leaves the composer expanded over the window, so the page never
returned to its portrait width. With **Collapse** added to the journey, the iPad
(`artifacts/expo-bootstrap/native-HRPtG8/`) and iPhone 18 Pro
(`artifacts/expo-bootstrap/native-oKyg0t/`) journeys passed with zero failures.

Rerun on 2026-11-24 for [#2866](https://github.com/unwired-dev/product/issues/2866),
same host, macOS 27.2.1, Xcode 27.2 (27B52), iOS 27.0 Simulator runtime, Release
`registration-draft-editor` build of `8dbd55782` with the journey's new link step,
Dark appearance. The iPhone 18 Pro (`artifacts/expo-bootstrap/native-06uxf8/`) and
iPad Pro 11-inch (M5) (`artifacts/expo-bootstrap/native-rdraMI/`) journeys passed
with zero failures: **Add Link** opened with the paragraph as Text and Link empty
and linked the paragraph, **Edit Link** offered **Remove Link** and the destination,
one **Undo** removed the link and kept the text with **Add Link** back, **Redo**
restored it, and the relaunched Draft reopened with the link and its destination.
Other attempts at loads of about 150–440 stalled waiting for the app to idle or
lost a tap on the Format panel before the link step; they are not evidence.

First Mac run on 2026-11-25 for [#2876](https://github.com/unwired-dev/product/issues/2876),
same Mac mini, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), signed `Testing`
`registration-draft-editor` build of `d72ed590e` with the journey's new link step,
Light appearance. `testIndependentWindowsCloseReopenAndQuit` passed with zero
failures in 479 s (`artifacts/macos-inbox/journey.vZfqPf/`), and again in 592 s with the
link matched by the whole paragraph (`artifacts/macos-inbox/journey.zzMdGX/`), from sign-in through the
formatting, assistance and reply round trips, the link step and the native close
journey: **Add Link** opened with the paragraph as Text and Link empty and focused,
without **Remove Link**, and linked the paragraph; **Edit Link** offered **Remove
Link** and the destination; one **Undo** removed the link and kept the text, **Redo**
restored it, and the relaunched Draft reopened with the link and its destination.
An earlier attempt failed at its first **Close** because crash alerts left by other
tasks covered the window; it is not evidence.

Mac image paste on 2026-11-25 for [#2929](https://github.com/unwired-dev/product/issues/2929),
same Mac mini, macOS 27.2.1 (26B131), Xcode 27.2 (27B52), signed `Testing`
`registration-draft-editor` build of `cf500a39d` with #2929's change, Light
appearance. `testIndependentWindowsCloseReopenAndQuit` from `8a1db32f1` passed with
zero failures in 460 s (`artifacts/macos-inbox/journey.Sp0jXC/`). After the relaunched reply Draft
reopened, the journey pressed Command-V at the end of the body twice, with a text
file and then a PNG on the general pasteboard: each time the page asked the host to
read the pasteboard; the file became an Attachment, and the image went inline with
its verified thumbnail and a **Pasted image** row. After **Save**, a relaunch and
reopening, both were in place. Before that step the
journey's numbered-list checks needed repair: since #2884 the page draws the marker
as the texts `1` and `.` ([#2926](https://github.com/unwired-dev/product/issues/2926)).
Earlier attempts of the same build failed at those checks and are not evidence.

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

Outstanding before any adoption decision: physical iPhone and iPad runs; hardware keyboards, IME, dictation,
autocorrection and VoiceOver ([#822](https://github.com/unwired-dev/product/issues/822));
the Inline Image checks that remain outstanding [below](#inline-images-820); and the
native save-ordering checks that remain outstanding [below](#save-ordering-821).
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
damaged bytes listed as damaged with no thumbnail sent are covered too. On every host a
paste request from the page runs the native pasteboard import; on Mac a pasted image
without a name of its own is named as in the current composer (#2929). The saved body uses the same Inline Image spans as the current composer, so
the existing outgoing-format boundary applies unchanged; this evaluation sends nothing.
These are not native evidence.

Component journeys also cover the composer layout: nothing is stored until **Save
Draft**; a refused save keeps the editor open with **Try Again** and still asks on the
next **Close**; an unchanged Draft closes and an empty one is removed without asking;
**Delete Draft** removes the Draft; a refused **Send** stays open with its reason and
stores the shown version; the iPhone Format panel, its keyboard hand-off and Writing
tools; the iPad format bar; and the conversion menu and its accessibility action.
The Mac component journey substitutes the native close module and checks window
routing, repeated requests, Cancel, failed Save and successful Save. The native
Mac journey also covers Command-W cancellation, cancelled Quit and one Quit
finishing two open editors; it passed on 2026-11-25 (#2876). Since #2938 it also
covers the window's close button and two windows on one Draft
([Save ordering](#save-ordering-821)).

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

On the Mac, `testDraftEditorInlineImage`
([#2948](https://github.com/unwired-dev/product/issues/2948),
[Mac Draft editor Inline Image journey](native-journeys.md#mac-draft-editor-inline-image-journey))
passed on 2026-11-26 with Xcode 27.2 (`27B52`) on macOS 27.2.1, in a signed
`registration-draft-editor` `Testing` build from main at `01c50416b`. **Insert Image…**
placed a PNG chosen in the system open panel after the typed text, and the page showed
its native thumbnail; **Attach Instead** and **Show Inline** from the row's context menu
converted it, and two **Undo** and two **Redo** stepped back and forward through both
conversions; after **Save**, a relaunch and reopening, the image was in place with its
thumbnail. The journey's mock copy needed the app's own user-selected file entitlement
for the open panel to appear.

Outstanding for #820: pasting image data into the page on Mac, and dropping files on the page on every
host, which need native interception in the web view (the page refuses both unread);
**Paste Image** and in-page paste on a device; and physical iPhone and iPad runs.
Website data after account removal and a network capture are recorded in
[Website data and network](#website-data-and-network-2922).

### Save ordering (#821)

[#821](https://github.com/unwired-dev/product/issues/821) was written for an editor
that saved while the person typed. Since #820, nothing is saved until **Save Draft**,
**Save** or **Send**, and editing pauses while that finishes, so no typing continues
during a save. Its ordering risks remain: page reports arriving after newer ones,
edits still queued in WebKit when a native control is pressed, failed saves, another
account, competing windows and imports.

Component journeys on both hosts send page messages through the real Draft store with
synthetic storage. In addition to the [#820](#inline-images-820) journeys, which cover
an edit queued in WebKit before the page acknowledges a finishing command, a refused
save with **Try Again**, locked storage and reopening, they check that:

- a late report of an earlier body revision, before or during **Save Draft**, never
  replaces the newer body, and a selection report arriving before its body does not
  prevent the final acknowledgement from storing that body;
- with two Mac windows on one Draft, the window that saves second keeps its version as
  a conflicting copy without remounting its page, even when storage refuses that save;
  its later edit and **Save** then store only the copy, and **Don’t Save** deletes
  only the copy;
- when **Delete Draft** (**Don’t Save** on Mac) races an image import after another
  device changed the Draft, the other device's version and its image bytes survive,
  and the abandoned import keeps no bytes;
- after another Product Account opens, **Save Draft** stores the open editor's version
  in neither account, and the earlier account keeps its stored version.

Page/store integration journeys in `happy-dom` also exercise the real page bridge,
Undo and Redo after a locked save creates a conflict copy, then durable Save and
Discard of that copy while the other version survives. The page tests also check
that the page refuses a replacement computed for another body revision. None of these are native evidence: native code delivers the page's messages in order, so late delivery is
simulated at the host boundary.

The native Mac journey ran both on 2026-11-25
([#2938](https://github.com/unwired-dev/product/issues/2938); signed
`registration-draft-editor` `Testing` build, macOS 27.2.1, Xcode 27.2, Mac mini M4;
`Executed 1 test, with 0 failures`). Two windows opened the same saved Draft in the
page, and each appended its own text. The first window saved its version. In the
second, the window's close button asked **Save**, **Don’t Save** and **Cancel**;
**Cancel** kept the window and its text, and **Save** closed it and kept its
version as a conflicting copy. After a relaunch, the conflicting copy held only
the second window's text and the original only the first's.

Outstanding for #821: the Mac two-window journey on one Draft and the window's close
button natively (the Command-W and **Quit** questions passed on 2026-11-25, #2876).
The page journals its unsaved edits to a composer recovery record as the current
composer does, and **Restore** reopens them in the page. On Mac
`testDraftEditorRecoveryAfterForceQuit` proves it after a force quit
([#2933](https://github.com/unwired-dev/product/issues/2933),
[Mac composer recovery journey](native-journeys.md#mac-composer-recovery-journey)), and
on iPhone and iPad `testDraftEditorRecovery` after XCUITest terminates the app
([#2944](https://github.com/unwired-dev/product/issues/2944),
[iPhone and iPad composer recovery journey](native-journeys.md#iphone-and-ipad-composer-recovery-journey)). The regular iPhone, iPad and Mac composers now
use the same save model. On iPhone both composers cover the
Inbox and reader, so system **Back** cannot leave them
([#778](https://github.com/unwired-dev/product/issues/778)).

### Website data and network (#2922)

[#2922](https://github.com/unwired-dev/product/issues/2922) checks
[ADR 0080](adr/0080-edit-the-draft-body-in-the-tiptap-page.md)'s gate 4: that
the page leaves no WebKit website data, also after the account leaves the device,
and that a network capture of a journey shows no connection from the page's
WebKit processes. It ran on 2026-11-25 with Xcode 27.2 (`27B52`), the iOS 27.0
Simulator runtime and macOS 27.2.1 on the Mac mini M4, from main at
`cf500a39d` with the journey repairs of #2923 and #2926, in
`registration-draft-editor` builds:
Release on iPhone and iPad, `Testing` on the Mac.

Method:

- A watcher listed every path in the app's data container every five seconds
  whose name contains `WebKit`, `Cookie`, `HTTPStorages`, `LocalStorage`,
  `IndexedDB`, `CacheStorage` or `ServiceWorker`. On the Mac it also listed the
  app's folders in `~/Library/WebKit`, `Caches`, `HTTPStorages` and `Cookies`.
  It recorded the process ids of the app and its WebKit WebContent, Networking
  and GPU processes.
- A temporary step at the end of each journey removed the mailbox in Settings ›
  Email Accounts and chose **Sign Out of This Device**, on the installation the
  journey used, and the watcher sampled on after it.
- `tcpdump` on the host's `pktap` interface recorded every TCP and UDP packet,
  including loopback, sent or received by a process named `com.apple.WebKit…`
  or on its behalf, with the process id, through each whole run. The
  Simulators' processes run on the host and are tagged the same way. pktap tags
  each packet rather than sampling: a probe connection that carried no data and
  closed after 18 ms appeared under its process. The kernel's capture
  buffer was raised to 32 MB for the runs, and the captures report no packet
  dropped.
- Controls in the same captures were recorded under their own process ids: on
  an iPhone Simulator, Safari loading `https://example.com/` (47 packets of its
  WebKit Networking process), and on the Mac a `WKWebView` with a
  non-persistent store loading the same page (35 and 36 packets in the two
  captures).

Results:

- The journey passed, through the removal and sign-out, on iPhone 18 Pro
  (`artifacts/expo-bootstrap/native-70kqaE/`, 141 samples) and on iPad Pro
  11-inch (M5) (`artifacts/expo-bootstrap/native-CwnaDf/`, 132 samples), and
  on the Mac (`artifacts/macos-inbox/journey.ZqMP9S/`, 106 samples). The iPad
  journey first stopped at its Link Editor step
  ([#2923](https://github.com/unwired-dev/product/issues/2923)) and the Mac
  journey at its numbered-list and link steps
  ([#2926](https://github.com/unwired-dev/product/issues/2926)); both are fixed.
- No sample found website data. From the first web view on, every iPhone and
  iPad sample (128 and 120) found only the WebKit GPU process's compiled shader
  cache in `Library/Caches/com.apple.WebKit.GPU` and the `tmp/com.apple.WebKit.GPU`
  and `tmp/com.apple.WebKit.Networking` folders, before and after the sign-out,
  and the earlier samples found nothing; on the Mac no sample found anything.
  In an earlier, shorter `agent-device` session on a fresh Simulator, no file in
  the iPhone or iPad container held the text typed into the page after sign-out.
- The captures hold only the controls' packets. None came from or for the
  journeys' WebKit processes: 49 on iPhone and 49 on iPad, across the app's 13
  launches on each, and on the Mac the 46 started during the run, across the
  app's 15 launches.

This does not show physical devices (gate 1) or real providers. The watcher reads
only the app's own folders; WebKit data a system process keeps elsewhere for the
app would not be seen. The capture shows only packets the host sends or receives:
it would not see data the page passes to another process without a network
connection.

### Composer opening (#2955)

[#2955](https://github.com/unwired-dev/product/issues/2955) measures one of
[#822](https://github.com/unwired-dev/product/issues/822)'s comparisons for
[ADR 0080](adr/0080-edit-the-draft-body-in-the-tiptap-page.md)'s gate 5: how long
each Mac composer takes to open a body, with the
[composer opening journey](native-journeys.md#mac-composer-opening-journey). It ran
on 2026-11-26 on the Mac mini M4 (`Mac16,10`, 16 GB) with macOS 27.2.1 (`26B131`)
and Xcode 27.2 (`27B52`), from `01c50416b` with the journey added, in signed
`Testing` builds: `registration-performance` for the current composer and
`registration-draft-editor` for the page. Each composer has 10 samples per
interaction.

| Composer | New message p50 / p95 / max | Saved Draft p50 / p95 / max |
| -------- | --------------------------- | --------------------------- |
| Current  | 499 / 1,581 / 1,581 ms      | 334 / 670 / 670 ms          |
| Page     | 294 / 687 / 687 ms          | 279 / 798 / 798 ms          |

A sample runs from the mouse release the app records until an accessibility query
finds the body ready: the body and the format bar's **Undo**, which the page shows
once it is ready, and for the saved Draft its paragraph in the body. It includes
XCUITest's event completion and queries (about 23–58 ms per query in these runs),
so each sample is an upper bound, and it leaves out the display frame that draws
the body. Both composers' p95 upper bounds exceeded the budgets of 300 ms for an
empty composer and 200 ms for a warm one, so these runs do not prove either budget.

The host was shared with other agents' builds and journeys: the one-minute load
average read 114 before and 51 after the current composer's run, and 263 before
and 44 after the page's. Both
runs recorded main-queue stalls of 100 ms or longer during new-message samples
(the current composer: 381, 111 and 127 ms; the page: 169 ms) and none during
saved-Draft samples, so the saved-Draft tails may come from other processes under
the same load. These runs therefore show neither that a composer misses the
budgets on an idle host nor which opens faster. Repeat
them on an idle host before reading them as a comparison. Physical iPhone and
iPad, and #822's startup, typing response and memory measurements, are still
outstanding.

## Finding

**Proceed** to the dependent evaluations (#819–#822) on iPhone and iPad. A
locally packaged Tiptap page edited, saved and reopened a Draft through the existing
encrypted Draft store on iPhone and iPad simulators, with networking refused, no
renderer dependency on React DOM, and no native adapter beyond the existing WebView.
No fundamental host failure was found there.

On the Mac, the signed journey passed on 2026-11-25
([#2876](https://github.com/unwired-dev/product/issues/2876)), with the same open,
type, save and reopen path, formatting, assistance and link editing. This finding is not an adoption
recommendation; that is #823, recorded in [ADR 0080](adr/0080-edit-the-draft-body-in-the-tiptap-page.md).

**#819 finding.** The current block kinds and marks pass the page and host checks
above. iPhone/iPad simulator and Mac text, history, the exercised post-assistance
formatting assertions and link editing with **Undo** and **Redo** (#2866, #2876) have
passing evidence. This does not approve adoption; #823
owns that decision.

**#820 finding.** Inline Images and Attachments keep their Draft Asset identity
through page editing, conversion, Undo, Redo, saving and reopening on iPhone and iPad
simulators, and the page receives only native thumbnails. Image paste and drop into
the page need native web-view work before they match the current composer on Mac,
and drops on every host. The current composer does not offer conversion yet. This
does not approve adoption; #823 owns that decision.

**#821 finding.** In component journeys on both hosts, **Save Draft** stores the
newest body the page reported even when an earlier report arrives late, conflicting
Mac windows keep separate copies, and racing imports, failed saves and account
changes lose no surviving content; natively, two Mac windows on one Draft keep both
versions (#2938). iPhone **Back** remains outstanding. This does not
approve adoption; #823 owns that decision.
