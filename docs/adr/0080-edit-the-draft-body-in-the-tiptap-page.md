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
  `@tiptap/pm`. Tiptap and ProseMirror needed no patch; the existing
  [WebView patch](../../patches/react-native-webview@14.0.1.patch) is unchanged,
  and no other native code was added.
- **Native runs.** iPhone 18 Pro and iPad Pro 11-inch (M5) Simulator journeys and
  the signed Mac `Testing` journey open, type, format, step Undo and Redo, run
  rewrites, translation and reply suggestions, edit links, save, relaunch and
  reopen a Draft through the encrypted Draft store
  ([Evidence](../draft-editor-evaluation.md#evidence); Mac on 25 November 2026,
  [#2876](https://github.com/unwired-dev/product/issues/2876)). iPhone and iPad
  also place, convert and reopen an Inline Image. Assistance results came from
  the build's synthetic model and Translation, so they prove the bridge and the
  edit, not Apple's models. No physical device ran.
- **Host failures.** None stopped the page on a host. Found and fixed during the
  runs: the review panel under the iPhone keyboard, a result dropped before the
  page loaded, rotation squeezing the body, the iPhone pill behind the keyboard and
  the iPad format bar clipping its menu. Still open: the page cannot read file
  drops on any host without native web-view interception (Mac image paste reads the
  pasteboard natively since [#2929](https://github.com/unwired-dev/product/issues/2929)), the
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
  copies. The page is minified into a string module, which the host bundle's
  source map lists alone; since
  [#2916](https://github.com/unwired-dev/product/issues/2916) the page build lists
  the files it bundles beside that module, so `scripts/licence-inventory.mjs` and
  the archive's `ThirdPartyNotices.txt` include the page's packages.
- **Measurements.** The packaged page is about 351 KB. No latency, memory or
  battery comparison with the current composer was measured:
  [#822](https://github.com/unwired-dev/product/issues/822) closed without a native
  result. The table probes compare behaviour, not speed.

## Assessment

- **Semantic Message Document.** `src/conversion.ts` is the only boundary; Drafts
  store only the document, never Tiptap JSON, HTML or Markdown, and the host
  decodes every page message with Schema. Page tests round-trip every ordered
  pair of the evaluated block kinds with mixed marks. Drafts now also hold list
  levels, alignment, colors, fonts and tables, which the evaluation conversion
  does not keep: #2884 and #2858 make them round-trip before any existing Draft
  opens in the page.
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
  reliable. A core-only BlockNote with a small schema would carry the same WebView
  host work; its core is MPL-2.0, whose distribution requires making its covered
  source, with changes to those files, available; only its optional XL email exporter is GPL-3.0 or paid
  ([licensing](../research/blocknote.md#licensing-and-cost)).
- **Lexical. Judgment:** the open risks (iOS VoiceOver, input methods in
  `contenteditable`, paste and drop interception) are WebKit's, so a bounded
  Lexical comparison would test nothing new for them. If one of them fails,
  investigate native editing, the split-region fallback of the table plan, rather
  than another web engine. The one Tiptap-side limitation seen is
  `prosemirror-tables` normalizing ragged rows as soon as they are edited
  ([table shapes](../architecture/draft-table-editing.md#what-the-evidence-does-not-show)).
  If #2858 can neither keep nor report those shapes, a Lexical comparison would
  test one hypothesis: ordinary typing in the same ragged-table fixture on the
  same host keeps its geometry.

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

The missing evidence makes these rollout gates, to be met before the page ships
outside evaluation builds; only gates 1, 3 and 5 may instead be recorded as a
release limit:

1. Physical iPhone and iPad runs, with hardware keyboards, IME composition,
   dictation, autocorrection and VoiceOver, including inside table cells.
2. Native exits as [#778](https://github.com/unwired-dev/product/issues/778)
   guards them for the current composer (iPhone **Back** and edge swipes, Mac
   window close, Command-W and **Quit**), and the Mac two-window journey on one
   Draft, run natively. On iPhone and iPad the evaluation loses open edits when the
   app ends before **Save Draft**; production must journal them to the encrypted
   recovery record of [ADR 0077](0077-remove-friction-that-privacy-does-not-require.md)
   and prove that they restore after a forced termination. On Mac the page journals
   them and restores them after a force quit since
   [#2933](https://github.com/unwired-dev/product/issues/2933). On iPhone the
   page composer is the system sheet over the Inbox, so **Back** and edge swipes
   cannot reach it; its downward swipe closes it as **Close** does, run natively on
   the iPhone Simulator by [#2961](https://github.com/unwired-dev/product/issues/2961).
   A compact iPad window has not run it.
3. The Mac Inline Image journey, file drops on every host, and **Paste Image**
   and in-page paste on a device. Image paste on Mac is met by
   [#2929](https://github.com/unwired-dev/product/issues/2929): native code reads
   the pasteboard, and the Mac journey pastes an image that reopens in place.
4. WebKit website data after account removal and a network capture of a journey.
   Met by [#2922](https://github.com/unwired-dev/product/issues/2922) on iPhone
   and iPad Simulators and the Mac: no sample found website data during the
   journey or after it removed the mailbox and signed the device out, and a
   per-process packet capture of the journey holds no packet of the app's
   WebKit processes
   ([evidence](../draft-editor-evaluation.md#website-data-and-network-2922)).
   Physical devices follow with gate 1.
5. [#822](https://github.com/unwired-dev/product/issues/822)'s comparison of
   both composers in Release builds on the same fixtures and devices, including
   selection-change latency on large, many-block Drafts
   ([review note](https://github.com/unwired-dev/product/issues/822#issuecomment-6114571758)),
   and the current composer's interactions the page lacks, such as the Slash
   Command Menu. On Mac, [#2955](https://github.com/unwired-dev/product/issues/2955)
   timed opening a new message and a saved Draft in both composers on a loaded
   host; repeat it on an idle one
   ([results](../draft-editor-evaluation.md#composer-opening-2955)).
6. The Tiptap and ProseMirror notices in the distributed app; the licence
   inventory must list the page's packages. Met by
   [#2916](https://github.com/unwired-dev/product/issues/2916): every bundle that
   carries the page lists its packages in the licence inventory, and release builds
   ship their notices.
7. Outgoing mail: the body is still serialized by mail-core from the document,
   and editor HTML is never sent. Packaged-client sends to real providers
   ([#1282](https://github.com/unwired-dev/product/issues/1282)) must verify the
   serialized MIME and what recipients see.

## Consequences

Tiptap and ProseMirror become production dependencies, and `verify:bundle` must
admit the page in production builds while keeping it out of the hosts' renderer
module graphs. The bridge, its ordering rules and the page's isolation become
production contracts. Should a gate fail on WebKit itself, the split-region
fallback needs its React Native probe of caret movement and selection first.
