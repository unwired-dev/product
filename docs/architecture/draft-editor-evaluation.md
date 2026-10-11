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

The page receives the opened body before its script runs and posts the whole body
after each edit. The host decodes each message against the Semantic Message Document
schema; a malformed message changes nothing. The page never receives encryption
keys, account identifiers or other Drafts.

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
