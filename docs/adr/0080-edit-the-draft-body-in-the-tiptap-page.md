---
status: accepted
---

# Edit the Draft body in the Tiptap page

## Context

The production composers on iPhone, iPad and Mac edit the Draft body in one
multiline `TextInput`, which cannot hold table cells
([#1268](https://github.com/unwired-dev/product/issues/1268)) or draw an image at
its display size. The [editor alternatives research](../research/editor-alternatives.md)
chose Tiptap core for a test-only evaluation, with Lexical as the fallback for a
Tiptap-specific limitation and [BlockNote](../research/blocknote.md) as a
comparison baseline. The [evaluation guide](../draft-editor-evaluation.md) and its
[architecture notes](../architecture/draft-editor-evaluation.md) record what was
built and proved; the [table-editing plan](../architecture/draft-table-editing.md)
records the probes of three ways to edit tables.

[#823](https://github.com/unwired-dev/product/issues/823) asks for an adopt, defer
or reject recommendation. The owner adopted the page on 24 November 2026
([#2856](https://github.com/unwired-dev/product/issues/2856)). This record is that
recommendation and the decision it supports. Facts link to their evidence;
**Judgment** marks the conclusions drawn from them.

## Evidence

- **Versions.** Tiptap 3.34.0 (`@tiptap/core`, `@tiptap/pm` and the extensions in
  the [evaluated packages](../draft-editor-evaluation.md#evaluated-packages)),
  built by esbuild 0.28.2 into one page, in the patched `react-native-webview`
  14.0.1 on both hosts. The table probes added `prosemirror-tables` 1.8.5 from
  `@tiptap/pm`. No vendor package is patched; the existing WebView patch is
  unchanged and no other native code was added.
- **Native runs.** iPhone 18 Pro and iPad Pro 11-inch (M5) Simulator journeys and
  the signed Mac `Testing` journey open, type, format, step Undo and Redo, run
  rewrites, translation and reply suggestions, edit links, save, relaunch and
  reopen a Draft through the encrypted Draft store
  ([Evidence](../draft-editor-evaluation.md#evidence); Mac on 25 November 2026,
  [#2876](https://github.com/unwired-dev/product/issues/2876)). iPhone and iPad
  also place, convert and reopen an Inline Image. No physical device ran.
- **Host failures.** None stopped the page on a host. Found and fixed during the
  runs: the review panel under the iPhone keyboard, a result dropped before the
  page loaded, rotation squeezing the body, the iPhone pill behind the keyboard and
  the iPad format bar clipping its menu. Still open: the page cannot read image
  paste on Mac or file drops on any host without native web-view interception, the
  first tap on iPhone only focuses the page, and WebKit adds its own iPhone form
  accessory bar and iPad shortcut group ([probes](../architecture/draft-table-editing.md#probes)).
- **Semantic differences** from the current composer
  ([Semantic mismatches](../draft-editor-evaluation.md#semantic-mismatches)): the
  page drops alignment, color, background and fonts
  ([#2884](https://github.com/unwired-dev/product/issues/2884) restores them), has
  no Slash Command Menu, shows Inline Images at thumbnail size
  ([#2786](https://github.com/unwired-dev/product/issues/2786)), and adds Tiptap's
  extra keyboard shortcuts and **Attach Instead** and **Show Inline**.
- **Licensing.** Tiptap, ProseMirror and esbuild are MIT and need no paid service
  or licence key; MIT requires their copyright and licence notices in distributed
  copies. The page is minified into a string module, so
  `scripts/licence-inventory.mjs`, which reads the host bundle's source map, does
  not list the page's packages.
- **Measurements.** The packaged page is about 351 KB. No latency, memory or
  battery comparison with the current composer was measured:
  [#822](https://github.com/unwired-dev/product/issues/822) closed without a native
  result. The table probes compare behaviour, not speed.

## Assessment

- **Semantic Message Document.** `src/conversion.ts` is the only boundary; Drafts
  store only the document, never Tiptap JSON, HTML or Markdown, and the host
  decodes every page message with Schema. Page tests round-trip every pair of block
  kinds and marks.
- **Encrypted assets.** Native code keeps the bytes and their custody; the page
  receives only verified thumbnails and names assets by identifier, and the host
  saves only assets it gave the page.
- **Draft synchronization.** The page uses the existing Draft store, save model,
  and conflicting copies. Component journeys cover late page reports,
  two Mac windows, racing imports, refused saves and another Product Account;
  native two-window and app-termination runs are outstanding.
- **Assistance.** Rewrites, translation and reply suggestions run through the
  current on-device capture and review, and the page refuses a result for another
  body revision. No vendor AI, Yjs or CRDT collaboration is enabled or adopted.
- **Comparison. Judgment:** the page is the only measured approach with one
  selection and one Undo history across paragraphs and cells, and it needs no new
  native code under [ADR 0067](0067-keep-native-code-to-a-minimal-vault.md). The
  current composer's native text view gets the system's input methods and
  VoiceOver, which the page has not shown on iOS.
  BlockNote was not built, so nothing here claims it would be faster or more
  reliable; it would carry the same WebView host work with a block UI the product
  does not use, and its email exporter is GPL-3.0 or paid.
- **Lexical. Judgment:** no failure is Tiptap-specific. The open risks (iOS
  VoiceOver, input methods in `contenteditable`, paste and drop interception) are
  WebKit's, so a bounded Lexical comparison would test nothing new. If one of them
  fails, investigate native editing, the split-region fallback of the table plan,
  rather than another web engine.

## Decision

**Adopt, conditionally.** The production Draft body on iPhone, iPad and Mac moves
to the Tiptap page through a separately scoped integration,
[#2865](https://github.com/unwired-dev/product/issues/2865): formatting parity
(#2884) and page tables ([#2858](https://github.com/unwired-dev/product/issues/2858))
first, then the composers, then table editing per host
([#2859](https://github.com/unwired-dev/product/issues/2859),
[#2860](https://github.com/unwired-dev/product/issues/2860),
[#2861](https://github.com/unwired-dev/product/issues/2861)). The current composer
remains until #2865 replaces it. The owner also accepted WebKit's own VoiceOver
table phrasing (#2856).

The missing evidence makes these rollout gates, to be met or recorded as a
release limit before the page ships outside evaluation builds:

1. Physical iPhone and iPad runs, with hardware keyboards, IME composition,
   dictation, autocorrection and VoiceOver, including inside table cells.
2. The Mac two-window journey on one Draft and the window's close button, run
   natively; edits lost when the app ends before **Save Draft**.
3. Image paste on Mac, file drops on every host, and **Paste Image** on a device.
4. WebKit website data after account removal and a network capture of a journey.
5. Selection-change latency on large, many-block Drafts in both composers, from
   the [#822 review note](https://github.com/unwired-dev/product/issues/822#issuecomment-6114571758).
6. The Tiptap and ProseMirror notices in the shipped app's licence inventory.
7. Outgoing mail: the body is still serialized by mail-core from the document,
   and editor HTML is never sent; MIME output and recipient rendering stay with
   the provider qualification issues, not with this editor.

## Consequences

Tiptap and ProseMirror become production dependencies, and `verify:bundle` must
admit the page in production builds while keeping it out of the hosts' renderer
module graphs. The bridge, its ordering rules and the page's isolation become
production contracts. Should a gate fail on WebKit itself, the split-region
fallback needs its React Native probe of caret movement and selection first.
