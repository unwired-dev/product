# BlockNote suitability for Unwired Mail

Researched 2026-10-09. Repository baseline: `7fd6bca67d44dd57d30e81b0ee264f6f8c95bd49`.
Scope: evaluate BlockNote as the authored message-body editor, not as a replacement
for the mail client, reader, storage, or delivery pipeline. This is research and a
prototype recommendation, not an adoption decision or implementation evidence.

Reviewed against main on 2026-10-10 at
`506964efae8a39ea391f05b4578bc92ea851f5e6`. The current composer includes
[Draft rewrites and reply suggestions](../draft-assistance.md) and
[Outbox sending](../outbox.md); a replacement editor must preserve those
boundaries. Their native model and recipient-client qualification limits remain
separate from this library research.

## Recommendation

**BlockNote is a plausible WebView composer candidate, but not a drop-in React
Native editor. Prototype it before committing to production adoption.** Its
formatting, extensible document model, and current mobile browser work are useful.
The material cost is integrating a browser editor with our semantic document,
native encrypted assets, save ordering, window conflicts, keyboard behavior, and
accessibility. The evidence below supports feasibility, not compatibility already
proved on our hosts.

Prefer an initial core-only evaluation with a deliberately small schema. Keep the
existing Semantic Message Document as the persistence and outgoing-content
contract. Do not introduce Yjs synchronization, cloud AI, or an XL subscription
just to evaluate the editor. These are recommendations based on the product
requirements and the documented integration surfaces below.

## What the library provides

BlockNote is a React block editor built on Tiptap and ProseMirror. It includes
formatting controls, slash menus, block movement, nesting, tables, media blocks,
and comments. It offers Mantine, shadcn, and Ariakit UI integrations; custom
interfaces are possible. This is broader than our current mail-formatting scope.
[Official overview](https://www.blocknotejs.org/),
[installation guide](https://www.blocknotejs.org/docs/getting-started),
[v0.55.0 React package](https://github.com/TypeCellOS/BlockNote/blob/v0.55.0/packages/react/package.json).

GitHub's latest-release endpoint resolved to **v0.55.0, released 2026-09-22** at
research time. That release promoted the mobile formatting toolbar from
experimental to supported and included phone Enter/toolbar fixes. Package metadata
was checked at that tag; website documentation is rolling and may describe newer
work. Pin and verify the evaluated version instead of treating every live example
as a v0.55.0 guarantee.
[Release](https://github.com/TypeCellOS/BlockNote/releases/tag/v0.55.0),
[latest release endpoint](https://github.com/TypeCellOS/BlockNote/releases/latest).

## Fit with our hosts

The published React package depends on Tiptap's web React integration and declares
both `react` and `react-dom` peers for React 18 or 19. Its custom render APIs use
HTML elements. The installation guide calls it client-only. **Inference:** the
documented UI cannot render directly through React Native's native renderer;
matching our React major version alone does not make it compatible.
[Package dependencies](https://github.com/TypeCellOS/BlockNote/blob/v0.55.0/packages/react/package.json),
[custom render API](https://www.blocknotejs.org/docs/features/custom-schemas/custom-inline-content),
[client setup](https://www.blocknotejs.org/docs/getting-started).

Our mobile host uses Expo 57, React Native 0.86.3, and React 19.2.3. Mac uses React
Native macOS 0.81.9, React Native 0.81.6, and React 19.1.4. Mac production validation
explicitly rejects React DOM in the native bundle and permits a patched WebView
for the isolated reader. Consequently, an evaluation should build the browser
editor as a separate local asset and bridge it into each host. An existing reader
WebView does not qualify an editable, JavaScript-enabled composer.
[Expo setup](../expo-client.md), [Mac setup and bundle constraints](../macos-client.md).

Mobile browser support is real, but does not establish native-host quality. The
official guide moves the toolbar above the software keyboard, recommends
`interactive-widget=resizes-content`, and notes that iOS lacks that viewport
feature and benefits from a scroll-container layout. **Unverified:** WKWebView
focus, selection, hardware keyboard shortcuts, IME composition, dictation,
VoiceOver, split-screen resizing, and Mac menu/undo integration in our app.
[Mobile compatibility](https://www.blocknotejs.org/docs/getting-started#mobile-compatibility).

No first-party React Native host adapter or qualification evidence for our native
hosts was identified in the sources examined. This is a search finding, not a
claim that embedding is impossible. Browser bundle size, launch time, memory,
typing latency, and bridge traffic have not been measured.

## Document model and email output

Our editor contract already includes paragraphs, headings 1–3, lists, quotes,
code blocks, five text marks, inline image positions, and defined undo behavior.
It also requires ordered autosave, retryable failures, and preserving competing
Mac edits as separate conflict Drafts. These behaviors must survive an editor
replacement; a formatting demo is insufficient evidence.
[Draft behavior](../drafts.md),
[Semantic Message Document and Draft Asset definitions](../domain/messages-and-delivery.md).

BlockNote can construct a schema containing only selected blocks, inline content,
and styles, and supports custom inline elements with stored properties. That
offers a credible place for an inline image carrying our asset identifier.
**Proposed integration:** explicit conversions between a constrained BlockNote
document and our versioned Semantic Message Document; native code continues to
own asset bytes and authorization. Prove positions, IDs, marks, nesting, and
selection semantics survive edits and reloads. Disable unsupported insertion
routes as well as hiding their menu items.
[Custom schemas](https://www.blocknotejs.org/docs/features/custom-schemas),
[inline content properties and rendering](https://www.blocknotejs.org/docs/features/custom-schemas/custom-inline-content),
[native Draft Asset behavior](../drafts.md#files-and-images).

BlockNote recommends its JSON document for lossless storage. Standard HTML and
Markdown conversion are explicitly lossy; the interoperability table lists email
as export-only. That does not establish a lossless mapping to our different
semantic schema. Do not replace our durable document with HTML, Markdown, or
BlockNote JSON without a separate migration decision.
[Format interoperability](https://www.blocknotejs.org/docs/foundations/supported-formats).

`blocksToFullHTML` reproduces BlockNote's internal HTML structure and needs its
wrappers/styles for equivalent appearance. `blocksToHTMLLossy` produces simpler
HTML and flattens children of non-list blocks. Markdown can also remove styling.
**Inference:** neither generic export should be treated as a tested email
renderer or a lossless import path for arbitrary received mail.
[HTML export](https://www.blocknotejs.org/docs/features/export/html),
[Markdown export](https://www.blocknotejs.org/docs/features/export/markdown).

There is a dedicated **`@blocknote/xl-email-exporter`**. It converts documents to
email HTML using React Email and supports custom schema mappings. This makes
BlockNote more relevant to email than its general HTML export alone suggests.
However, it is an XL package, and its default file resolver uses a
**BlockNote-hosted proxy**. A private-mail integration must replace that resolver
with the authorized local asset path and verify actual network behavior. Its docs
also explain that generated data-URL images fail in some Gmail/Outlook clients and
describe CID attachment delivery. It does not establish MIME/provider delivery
compatibility for our app.
[Email exporter and options](https://www.blocknotejs.org/docs/features/export/email),
[exporter package dependencies and license](https://github.com/TypeCellOS/BlockNote/blob/v0.55.0/packages/xl-email-exporter/package.json).

Recommendation: evaluate editing independently from outgoing serialization. Keep
our semantic export boundary; assess the XL exporter only if it reduces measured
email-rendering work enough to justify its ongoing license and integration cost.

## Offline operation, synchronization, and AI

BlockNote integrates Yjs and delegates transporting updates to a provider. Its
docs list hosted and self-hosted providers, and `y-indexeddb` for offline storage.
This is an optional collaboration building block, not our encrypted persistence
or Product Sync implementation. **Recommendation:** initially use a local editor
with our existing ordered save bridge. Do not silently replace conflict Drafts
with CRDT merging or store private Drafts in browser IndexedDB.
[Collaboration documentation](https://www.blocknotejs.org/docs/features/collaboration),
[current save and storage behavior](../drafts.md).

BlockNote's AI integration uses the Vercel AI SDK, supports model/provider choice,
streaming edits and acceptance UI, and is documented as early preview in
`@blocknote/xl-ai`. Our On-Device Mail Assistance requires Apple system models,
explicit opt-in, tightly limited context, and no cloud/backend fallback; previews
remain separate until acceptance. Therefore its default AI integration is not a
drop-in fit. Whether its UI is worth adapting to our native assistance boundary is
unproven and unnecessary for a composer evaluation.
[BlockNote AI](https://www.blocknotejs.org/docs/features/ai),
[our assistance contract](../domain/assistance.md).

## Licensing and cost

The tagged repository license distinguishes non-XL source under **MPL-2.0** from
`packages/xl-*` under **GPL-3.0**, with a commercial alternative. Core can be used
in a closed-source product; it is not MIT. Mozilla's guidance describes
file-level copyleft: distribution requires preserving notices and making covered
source, including modifications to covered files, available; separate proprietary
files in a larger work can remain proprietary. This is a source-based summary,
not a legal opinion.
[Tagged LICENSE.txt](https://github.com/TypeCellOS/BlockNote/blob/v0.55.0/LICENSE.txt),
[Mozilla MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/).

The email exporter's package explicitly declares `GPL-3.0 OR PROPRIETARY`.
Commercial use and closed-source use are different questions: a paid license is
needed when using XL without complying with its GPL route, not merely because
the application earns money. Core formatting, generic HTML/Markdown export, and
collaboration do not themselves require XL.
[Exporter license field](https://github.com/TypeCellOS/BlockNote/blob/v0.55.0/packages/xl-email-exporter/package.json),
[pricing/licensing FAQ](https://www.blocknotejs.org/pricing),
[format/package matrix](https://www.blocknotejs.org/docs/foundations/supported-formats).

At research time the Business page displayed **$195/month billed annually
($2,340/year)** and a **$390/month** comparison price; confirm the selected billing
cadence at purchase. Business lists AI, multi-column layouts, and PDF/DOCX/ODT/email
exporters. This is a budget reference, not a quote.
[Current pricing](https://www.blocknotejs.org/pricing).

The commercial terms specify one Application and one production environment,
five developer seats, a 30-day non-production trial, and an active subscription
for continued deployed use; standard plans are not perpetual. “Application” is
defined differently for web domains and desktop/mobile executables. **Unresolved:**
whether our iOS/iPadOS and macOS distributions are covered together. Obtain
written vendor clarification before choosing XL; do not assume one subscription
covers every host. No vendor contact or purchase occurred during this research.
[Commercial terms, sections 1, 2.2, 2.4, 2.7, 3.2 and 7.2](https://www.blocknotejs.org/legal/blocknote-xl-commercial-license).

## Proposed evaluation and decision gates

These are proposed checks, not completed tests. Limit the first spike to core
editing and our current document subset on all three native form factors.

1. **Host boundary:** package a local web asset without adding React DOM to the
   native renderer; prove launch, focus, resize, and teardown on iPhone, iPad,
   and Mac. Confirm the shipped assets work with networking disabled.
2. **Document fidelity:** round-trip existing Draft fixtures, all supported
   blocks/marks, mixed lists, empty paragraphs, Unicode, inline images and asset
   IDs. Reject or explicitly normalize unsupported pasted content without silent
   loss. Keep quoted correspondence and recipients outside authored-body edits.
3. **Editing quality:** exercise IME, dictation, selection, caret formatting,
   input shortcuts, hardware keyboard, VoiceOver, and grouped undo/redo. Test
   selection around inline images and iPad keyboard/split-view transitions.
4. **Durability and privacy:** race typing with saves, failures, close/reopen,
   app interruption, stale Mac windows and account removal. Demonstrate the same
   conflict/save outcomes as the existing composer, no credential/key transfer
   into web code, and no unintended remote file/proxy requests.
5. **Email output:** compare our semantic renderer with any proposed exporter
   using real Gmail, Apple Mail and Outlook rendering, including CID images,
   lists, quotes and plain-text alternatives. A browser preview alone is not
   recipient-client evidence.
6. **Cost and maintenance:** measure bundle size, startup, memory and editing
   responsiveness against the current composer; record required overrides or
   forks. Resolve XL multi-host licensing only if XL remains part of the proposal.

Proceed only if the native experience and document/durability invariants pass
without a substantial editor fork. Stop if the required native behavior cannot
be achieved, private assets require external resolution, or mapping silently loses
document content. A web composer could still be a separate future use even if the
native-host spike fails; no web host adoption is proposed here.

## Evidence limits

Completed: official docs, tagged package metadata/license and release research,
and comparison with current repository operational and domain documentation.
Not performed: dependency installation, editor prototype, native build or UI
tests, accessibility validation, bundle/performance measurements, actual outgoing
email rendering, or commercial licensing confirmation. No production code,
dependencies, storage formats, or native policy were changed.
