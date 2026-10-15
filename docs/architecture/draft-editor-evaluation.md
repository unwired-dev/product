# Tiptap Draft editor evaluation: architecture notes

Reviewer-only companion to [the evaluation guide](../draft-editor-evaluation.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
This test-only evaluation does not adopt or replace the production editor.

## Scenario selection

This selection was decided by the
[decision panel](../agents/implementation-review.md#decision-panel): a separate build
flag usable with real accounts (option B) lost 3–0 to the scenario-bound selection
(option A). Panelists `claude-fable-5-1`, `gpt-6.1-sol` and `gpt-6-astra` each chose
A because it satisfies the disposable-Draft requirement by construction and reuses
the existing scenario validation and bundle checks. Trying the editor with real
accounts needs its own later decision.

## Page and conversion boundary

The editor is one HTML page built from `packages/draft-editor` and bundled into the
JavaScript as a string. Its script and styles are inline, and its Content Security
Policy refuses every other source (`default-src 'none'`). The WebKit view is
non-persistent (`incognito`), cache-free, cannot open windows, and cancels every
navigation except its own page. No cloud collaboration, vendor AI, remote asset
service, browser persistence or paid editor service is used.

The page receives the opened body before its script runs and reports its revision,
display selection, active marks, block kind and history availability after every
transaction, including an initial ready update. It includes the whole body after
each authored edit. The shared message decoder validates every update, including
its optional body, against Effect Schema; a malformed message changes nothing. The page never receives encryption
keys, account identifiers or other Drafts.

Before Close, Save or Send inspects the Draft, the host makes the page read-only
and waits for an ordered acknowledgement of its final document. Native fields and
asset controls are disabled during that operation. A refused finish restores editing;
page termination or editor teardown cancels an outstanding acknowledgement. This
keeps queued WebKit edits inside the version that is saved or admitted to the Outbox.
The host tracks page-state and accepted-body revisions separately: a selection-only
report cannot stand in for its document. An acknowledgement at the already-accepted
body revision is not another authored edit. Older page reports are ignored.
Asset settlement patches both the editor and its stored baseline, preserving their
shared identity when the person has made no edit. Navigation waits for the close
choice and resumes only after a successful save or deletion.

`src/conversion.ts` is the only boundary between the Semantic Message Document and
Tiptap's JSON. Drafts store only the Semantic Message Document; Tiptap JSON, HTML or
Markdown are never stored. The object replacement character that marks an Inline
Image is removed from typed or pasted text.

Tiptap runs inside the page only. The hosts' bundles contain no React DOM, Tiptap or
ProseMirror modules; `verify:bundle` fails if Tiptap or ProseMirror join either
renderer's module graph, or if the page appears in any bundle other than
`registration-draft-editor`.

## Host adapter

**TenTap was not used.** Both hosts already render message bodies in the patched
`react-native-webview` 13.16.1, which supports AppKit through `react-native-macos`.
One page and one bridge serve all three hosts. TenTap targets iOS and Android and
would add a second bridge for iPhone and iPad without covering the Mac.

## Formatting fidelity (#819)

### Editor configuration

No vendor package needed a patch. The editor configures Tiptap to the document's
rules instead:

- List items and quotes hold paragraphs only, and each further paragraph of a list
  item becomes an item of its own, because the document has no nesting.
- The page handles Return in empty list items and quote lines before Tiptap's
  default keymaps can lift them into paragraphs, preserving the current composer's
  continuation behavior and placing the caret in the new item or line.
- A code block is one code line per textblock, as the document stores it, with
  marks allowed; Return in code always starts another line, so leaving a code block
  uses the **Code block** control.
- Inline code combines with the other marks, which Tiptap's default excludes.
- Tiptap's own input and paste rules are off; the page applies the documented
  shortcuts itself so that Undo restores the literal marker.
- **Links are not representable.** The current Semantic Message Document has no link,
  so the editor offers no link authoring and drops pasted destinations. Adding links
  to the document for both composers is
  [#878](https://github.com/unwired-dev/product/issues/878) (see
  [Decisions](#decisions)).
- Tiptap's extra keyboard shortcuts (for example Command-E for inline code and
  Command-Option-1 for a heading) also work in the page; the current composer
  documents only Command-B, Command-I and Command-U.

### Decisions

Links (decision panel, 2026-10-11). Option A extended the durable document with
validated link destinations for both composers, storage, sync and outgoing mail
within #819; option B kept the document unchanged, records links as a semantic
mismatch, and moves link support to a follow-up issue that blocks the adoption
decision. B won 3–0 (`claude-fable-5-1`, `gpt-6.1-sol`, `gpt-6-astra`): adding
durable link semantics is a product-format change for both composers that deserves
its own slice, and the evaluation should expose the gap rather than close it.

**#819 finding.** Tiptap can hold every block kind and mark the current Semantic
Message Document has, with Markdown shortcuts, word-step history and assistance
results that match the current composer, without patching any vendor package. It
needed configuration to stay within the document: no nesting, one textblock per code
line, inline code combined with other marks, its own shortcuts in place of Tiptap's
input rules, and a normalizer after each edit. Links are the gap: the document cannot
store them, so link editing waits for
[#878](https://github.com/unwired-dev/product/issues/878), which blocks #823. The Mac
host remains unproven for formatting too.
