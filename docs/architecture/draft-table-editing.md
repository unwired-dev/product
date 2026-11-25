# Draft table editing: architecture plan

Plan for [#2785](https://github.com/unwired-dev/product/issues/2785), a slice of
[#1268](https://github.com/unwired-dev/product/issues/1268). It chooses how the
production composers on iPhone, iPad and Mac edit tables in a Draft body. It
changes no production behaviour; the slices at the end do.

## Starting point

- mail-core reads tables from HTML and writes them to outgoing mail
  ([#1878](https://github.com/unwired-dev/product/issues/1878),
  [#1886](https://github.com/unwired-dev/product/issues/1886)); the reader rules
  are in [Drafts](../drafts.md). `TableSchema` in `packages/mail-core/src/semantic-document.ts` stores rows of cells, each with its own blocks, optional column and row spans and, since [#2857](https://github.com/unwired-dev/product/issues/2857), a header flag.
- `DraftSchema.body` in `packages/mail-core/src/draft-model.ts` is a `TableDocument` since #2857: Drafts keep tables through save and reopen, and the composers edit `textOf(body)` and write it back with `withText`, which leaves tables in place without showing them.
- Both production composers edit the body in one multiline `TextInput` whose
  children are styled `Text` runs (`apps/mobile/src/composer.tsx`,
  `apps/macos/src/composer.tsx`). Undo and Redo are JavaScript-owned
  (`packages/mail-core/src/editor-history.ts`). A `TextInput` cannot hold cells.
- The [Tiptap evaluation editor](draft-editor-evaluation.md) is one bundled page in
  `react-native-webview` on all three hosts, behind a validated message bridge.
  Its adoption is recorded in [ADR 0080](../adr/0080-edit-the-draft-body-in-the-tiptap-page.md)
  for [#823](https://github.com/unwired-dev/product/issues/823).

## Approved behaviour

The owner approved the table-editing frames, Light and Dark, on
[6 November 2026](https://github.com/unwired-dev/product/issues/1268#issuecomment-6690275081):
Mac section 948:8162, iPad section 949:16357, iPhone section 949:25964.

1. The caret goes in a cell; the focused cell shows a 2 pt `accent/fill` outline
   inside it, with the system insertion point and selection. The outline follows
   the caret and disappears when the caret leaves the table.
2. Tab moves to the next cell and selects its text; Shift-Tab moves to the previous
   cell. Tab in the last cell moves the caret to the text after the table and never
   adds a row.
3. Return adds a line inside the cell.
4. Backspace after a table does not merge into it. Deleting a whole-table selection
   is one Undo step.
5. Format marks apply inside cells. There are no table-building tools.
6. Nested tables and images inside cells keep being reported and are not opened for
   editing.
7. On iPhone the table scrolls sideways inside its own frame.
8. VoiceOver: "Table, 5 rows, 3 columns"; "2 Dec, Date, row 3 of 5"; a merged cell
   "row 5, columns 1 to 3".

## Probes

Probes ran on 24 November 2026 on a macOS 27.2.1 Mac mini and iOS 27.0 Simulators
(iPhone 18 Pro, iPad Pro 11-inch M5) with the iOS 27.2 SDK. Each host showed the
same Draft: a paragraph, a 5-row by 3-column table with a header row and a last
row of one cell spanning three columns, then a paragraph. Keys and clicks were
synthesized on the Mac (System Events, CGEvent) and driven through XCTest on iOS.
The probe code was temporary and is not in the repository.

### C. Tiptap page in WebKit

Tiptap 3.34 with `prosemirror-tables` 1.8.5 from `@tiptap/pm`, a 15-line Tab
command, `tableEditing({ allowTableNodeSelection: true })`, a decoration that
outlines the caret's cell, and the table in an `overflow-x: auto` wrapper.

- **Mac.** Tab and Shift-Tab moved cell to cell through the merged row. Tab in the
  last cell moved to the paragraph after the table and added no row. Return added
  an empty paragraph inside the cell, and Command-Z removed it. Backspace at the
  start of the paragraph after the table moved the selection to the table and
  changed no text; a second Backspace deleted the whole table; one Command-Z
  restored it and one Command-Shift-Z deleted it again. In an earlier run with the
  default `allowTableNodeSelection: false`, the same Backspace selected every cell
  and emptied them, keeping the table, so the option is required. The accessibility
  tree held `AXTable` (5 rows, 3 columns), `AXRow`, `AXColumn` and `AXCell`
  elements with row and column index ranges; the merged cell spanned columns 0+3.
- **iPhone.** A tap put the caret in a cell after a first tap focused the page.
  Tab selected the next cell's text. Moving to an off-screen column scrolled the
  table sideways inside its own frame, and the outline showed on the focused cell.
  WebKit added its own form accessory bar above the keyboard.
- **iPad.** Tab walked all 13 cells to the merged row and the outline followed.
  The shortcut bar showed WebKit's own bold, italic and underline group.

### B. Native text view with `NSTextTable`

- **Mac `NSTextView`.** Tab and Shift-Tab moved between cells natively. Return after a cell's text started a paragraph
  outside the table. The accessibility tree was one `AXTextArea`, with no table,
  rows or cells.
- **iOS `UITextView`.** The iOS 27.2 SDK exposes `NSTextTable` and
  `NSTextTableBlock` in UIKit. On iOS 27.0 the view drew the table through
  TextKit 1 but fitted it to the width, with no sideways scrolling; the paragraph
  after it overlapped the last row's border. Tab typed a tab character, Return
  added a line inside the cell, and the accessibility tree held one text view with
  no table.

### A. Split regions

One text view per cell, as React Native's multiline `TextInput` is a
`UITextView` or `NSTextView` subclass.

- **Mac.** Tab and Shift-Tab moved focus between cell views through
  `doCommandBySelector:`. Select All selected one cell only, so Delete cleared one
  cell. The accessibility tree was 14 separate `AXTextArea` elements, no table.
- **iOS.** XCTest typed `\t` as text, so the probe could not drive a Tab key
  command; the production composer already routes hardware Tab to JavaScript
  through `UnwiredArrowKeys` (`native/design/UnwiredDesign.m`), proven by
  `testListIndent` in `apps/mobile/native-tests/InboxTests.swift`.
- **React Native.** React Native 0.88.1 on iOS implements no
  `UIAccessibilityContainerDataTable` and maps no role to a table container.
  `react-native-macos` 0.83.0 maps `table`, `row` and `cell` roles but sets no row
  or column counts or index ranges. Row and column phrases would have to be
  written into each cell's label.

## Comparison

| Cost               | A. Split regions                                                                                                                                                               | B. Native text view                                                                                                                                            | C. Tiptap page                                                                                                                                          |
| ------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Native code        | None for editing; an accessibility container per platform for table semantics.                                                                                                 | A new text view on each platform with table layout, key handling, sideways scrolling and accessibility. It is an editor, not a minimal adapter under ADR 0067. | None new: the evaluation page and bridge already run on all three hosts.                                                                                |
| Selection          | One selection per view. Select All, Shift-arrow and copy across cells and paragraphs need a JavaScript selection model over many views; the probe's Select All stopped at one. | One native selection across the body.                                                                                                                          | One ProseMirror selection across paragraphs and cells, with cell and table selections.                                                                  |
| Undo and Redo      | The existing JavaScript history can span regions, but each view keeps its own system undo that has to be suppressed.                                                           | System undo in the view; the JavaScript history and the Semantic Message Document need a converter from attributed text.                                       | One ProseMirror history; whole-table deletion was one step both ways.                                                                                   |
| Input methods      | Marked text and dictation end whenever focus moves between views; autocorrection and spelling state are per view.                                                              | Native, in one view.                                                                                                                                           | WebKit's own `contenteditable` input; the evaluation has not measured IME composition in tables.                                                        |
| VoiceOver          | No table without native containers; phrases written into labels.                                                                                                               | One text area on both platforms in the probes: no table, rows or cells.                                                                                        | Mac: a real table with rows, columns and spans. iOS: not proven (no VoiceOver in the Simulator; XCTest reports web table parts as Other).               |
| Keyboard           | Tab reaches JavaScript on both platforms; every other key between regions (arrows across cell edges, Backspace at a cell start) is JavaScript work.                            | Mac Tab works, Return leaves the table. iOS Tab types a tab character. Both need key overrides.                                                                | Forward Tab matched the frames on all three hosts after one Tab command; Shift-Tab, Tab leaving the last cell, Return and Backspace matched on the Mac. |
| Approved behaviour | Outline and sideways scrolling are straightforward; Backspace, whole-table deletion and VoiceOver phrases are custom.                                                          | Sideways scrolling and the outline are not available from `NSTextTable` on iOS; Return and Tab disagree with the frames.                                       | Every keyboard, outline and scrolling behaviour shown on at least one host; marks in cells, nested content and iOS VoiceOver not probed.                |

## Decision

**C. The owner adopted the Tiptap page as the production Draft body on 24 November 2026 ([#2856](https://github.com/unwired-dev/product/issues/2856)).**
Only C gave one selection and one Undo history across paragraphs and cells, and it
met forward Tab on all three hosts, and Shift-Tab, Tab leaving the last cell, Return, Backspace and whole-table Undo on the Mac, with no new native code.
A rebuilds a rich-text editor's selection, history, input-method and accessibility
model across many native views. B would need a native editor per platform, which
ADR 0067 rules out, and it still showed no table to VoiceOver.

An advisory council (`gpt-6.2-sol`, `gpt-6.2-astra`, `claude-fable-5-2`) chose C
3–0, each conditional on the owner's adoption decision, with Draft storage first
because it does not depend on the editor.

Replacing the production body was the owner's decision, which this plan filed ahead of the slices. The owner also accepted WebKit's own VoiceOver table phrasing: the approved strings name what VoiceOver must convey (table size, a cell's column header and row, a merged cell's column range), not exact wording, so no custom accessibility labels are added. [ADR 0080](../adr/0080-edit-the-draft-body-in-the-tiptap-page.md) records the adoption for [#823](https://github.com/unwired-dev/product/issues/823). A, with the costs above, stays the fallback should the page fail in production; it needs a React Native probe of caret movement and selection across regions first, since the bare-view probe here bounds its cost from below and does not show it is feasible.

### What the evidence does not show

- **iOS VoiceOver.** The Simulator has no VoiceOver and XCTest reports web table
  parts as Other. WebKit exposes tables on the Mac; on iOS it is unverified until a
  device run.
- **VoiceOver wording.** WebKit speaks its own table phrasing, which may differ from the approved "2 Dec, Date, row 3 of 5"; the owner accepted it in #2856.
- **The evaluation's own gaps.** At the probes, the [evaluation guide](../draft-editor-evaluation.md)
  listed the signed Mac native journey, physical iPhone and iPad runs,
  hardware keyboards, IME, dictation, autocorrection and VoiceOver as outstanding
  before any adoption decision. The signed Mac journey passed on 25 November 2026
  ([#2876](https://github.com/unwired-dev/product/issues/2876)); the rest are
  [ADR 0080](../adr/0080-edit-the-draft-body-in-the-tiptap-page.md)'s rollout gates. The probe page also lacked the evaluation page's
  normalizer, conversion and save ordering.
- **Header identity.** The probe page started from real `th` cells. Storage keeps the header flag since #2857; the page's conversion must carry it (slice 3).
- **Keys and input.** Simulator Tab injection is not a physical keyboard; IME
  composition, dictation and autocorrection inside cells were not exercised.
- **Marks and nested content in cells.** Format marks inside cells and reported
  nested tables and images were not probed; slice 3 covers them with page tests.
- **Formatting parity.** The page's conversion carries and shows the current
  composer's alignment, list levels, colors and fonts since
  [#2884](https://github.com/unwired-dev/product/issues/2884), the first slice of
  #2865's production integration. Editable cells carry them too, through the
  same conversion, with each cell numbering its lists from 1; a kept table keeps
  its cells' formatting unchanged and shows their text only. Inside cells,
  Backspace and Delete never join text across a cell's edge or a table, which
  they select first; a deletion across lines removes whole tables inside it; and
  selected cells or a selected table are cleared, cut, typed and pasted over by
  the table editing.
- **Table shapes.** `prosemirror-tables` normalizes tables as soon as they are
  edited: typing in a table whose rows have two and one cells adds a cell to the
  short row. mail-core accepts such ragged tables, so the page must define which
  shapes it edits unchanged and keep or report the rest.
- **A table that ends the body.** The probe always had a paragraph after the
  table; Tab in the last cell must create or reach a paragraph after it.

## Inline images at display size

The same change serves the remaining [#1735](https://github.com/unwired-dev/product/issues/1735)
slice ([#2786](https://github.com/unwired-dev/product/issues/2786)). A `TextInput`
cannot draw an image inside its text; the page already shows Inline Images and
runs a `resize` command, and draws them at thumbnail size. Drawing them at the
stored display size is a page change, except that Original size and the size caption need the image's verified dimensions, which the bridge does not pass yet; the Mac corner handles and the iPad and
iPhone touch-and-hold menu are host work on the same page. Under A, an image would
be one more non-text region in the split body.

## Slices

Each slice is one pull request and a sub-issue of #1268, in blocked-by order.

1. **[#2856](https://github.com/unwired-dev/product/issues/2856) Owner decision** (decided): the Tiptap page becomes the production Draft body, and WebKit's VoiceOver table phrasing is accepted. The production integration of the page is [#2865](https://github.com/unwired-dev/product/issues/2865), which slices 4 to 6 also wait for.
2. **[#2857](https://github.com/unwired-dev/product/issues/2857) Draft storage of tables** (delivered): `DraftSchema.body` accepts tables with header and merged cells, and the composers keep them intact without showing them. Live provider round trips stay with the provider Draft issues, such as #1269.
3. **[#2858](https://github.com/unwired-dev/product/issues/2858) Page tables**
   (delivered; the [evaluation guide](../draft-editor-evaluation.md#formatting-and-history)
   lists the shapes it edits): conversion between table cells and Tiptap, the table shapes it edits unchanged, the Tab
   command (including a table that ends the body), Return, Backspace after a
   table, whole-table selection as one Undo step, marks in cells and the
   focused-cell outline, tested in the page.
4. **[#2859](https://github.com/unwired-dev/product/issues/2859) Mac** (blocked by
   1, 3 and #2865): frames 948:8167, 948:8322, 948:8478, 948:8633, with the accessibility table checked through the AX tree and the VoiceOver phrases spoken.
5. **[#2860](https://github.com/unwired-dev/product/issues/2860) iPad** (blocked by
   1, 3 and #2865): frames 949:16362, 949:16927, 949:17493, 949:18058, with a hardware
   keyboard, WebKit's own bold, italic and underline group removed from the
   shortcut bar, and the VoiceOver phrases checked on a device.
6. **[#2861](https://github.com/unwired-dev/product/issues/2861) iPhone** (blocked
   by 1, 3 and #2865): frames 949:25969, 949:26287, 949:26606, 949:26924, sideways
   scrolling, a first tap that places the caret, no WebKit form accessory bar, and
   the VoiceOver phrases checked on a device.
