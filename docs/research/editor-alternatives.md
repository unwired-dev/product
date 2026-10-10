# Editor alternatives for Unwired Mail

Researched 2026-10-09. Scope: replacing or improving the authored message-body
editor on iPhone, iPad and native Mac. This is a sourced suitability assessment,
not an adoption decision or evidence from a working integration. This comparison
supersedes the earlier [BlockNote assessment](blocknote.md)'s initial prototype
priority; that report remains a conditional comparison baseline.

Reviewed against main on 2026-10-10 at
`506964efae8a39ea391f05b4578bc92ea851f5e6`. The current
[Draft assistance](../draft-assistance.md) and [Outbox](../outbox.md) are
integration baselines to preserve, with the qualification limits documented in
their guides.

## Recommendation

**Evaluate Tiptap core first, with TenTap as a possible mobile host adapter;
keep Lexical as a fallback for a concrete Tiptap-specific limitation.** These
offer more control over
our small semantic email schema than adopting an entire block-document UI.
This is a fit judgment, not a claim that either performs better than BlockNote.
Tiptap and Lexical expose custom content models; neither documented web editor
renders directly through React Native. Their native-host costs are still material.
[Tiptap extensions](https://tiptap.dev/docs/editor/core-concepts/extensions),
[Lexical introduction](https://lexical.dev/docs/intro).

If system-native editing is a hard requirement, retain the current composer as
the baseline and evaluate native components separately. The native packages
examined below do not establish a complete, shared replacement across our two
React Native hosts. Do not adopt a library merely because its website says
“mobile” or because its React peer version matches.

## What our use case actually requires

The editor must preserve paragraphs, headings 1–3, bulleted/numbered lists,
quotes, code blocks, and five marks: bold, italic, underline, strike and inline
code. Formatting applies to selections or subsequent typing; Markdown shortcuts
and their undo behavior matter. Inline images occupy semantic positions and
retain stable Draft Asset references through deletion and undo. Native code owns
encrypted original bytes; the editor receives limited display thumbnails.
[Draft behavior](../drafts.md#composing),
[files and images](../drafts.md#files-and-images).

The durable contract remains our **Semantic Message Document**, not editor HTML,
Markdown, or a vendor JSON format. Ordered saves, retryable failures, close/save
coordination, stale-window conflict Drafts, and encrypted Product Sync must
survive. Assistance stays explicit, on-device, revision-bound and separate until
acceptance. Editor collaboration or vendor AI is not a substitute for those
behaviors. The accepted assistance contract includes default-off enablement;
the current Draft assistance guide identifies that gate as follow-up work in
[#788](https://github.com/unwired-dev/product/issues/788).
[Draft durability](../drafts.md), [current Draft assistance](../draft-assistance.md),
[document and asset definitions](../domain/messages-and-delivery.md),
[assistance contract](../domain/assistance.md).

Mobile uses Expo 57 / React Native 0.86.3 / React 19.2.3; Mac uses React Native
macOS 0.81.9 / React Native 0.81.6 / React 19.1.4. The Mac native production
bundle rejects React DOM. **Proposed web integration:** a separately built,
locally packaged browser editor inside a WebView, with an explicit native bridge.
The existing reader WebView is not evidence that editing works acceptably.
[Expo setup](../expo-client.md), [Mac constraints](../macos-client.md).

## Shortlist

| Candidate                           | Actual rendering path                           | Fit judgment                                                         | Main unresolved work                                              |
| ----------------------------------- | ----------------------------------------------- | -------------------------------------------------------------------- | ----------------------------------------------------------------- |
| **Tiptap / ProseMirror**            | Browser DOM; separate WebView in our hosts      | First engine to prototype; explicit schema and custom attributes     | Native bridge, keyboard/accessibility, semantic conversion        |
| **TenTap**                          | Tiptap in a WebView with React Native controls  | Mobile accelerator for the same engine, not a separate engine choice | Mac host adaptation and save/flush protocol                       |
| **Lexical**                         | Browser contenteditable; separate WebView       | Conditional fallback for a concrete Tiptap-specific limitation       | Host integration, custom nodes, conversion and toolbar            |
| **Enriched HTML**                   | Native iOS/Android; separate Web implementation | Interesting native mobile alternative                                | No documented native Mac support; HTML and asset mapping          |
| **Enriched Markdown**               | Native iOS/Android/macOS input                  | Relevant future candidate                                            | Missing composer formats; documented Mac accessibility gap        |
| **Existing/native editor approach** | Native host components                          | Necessary UX/durability baseline                                     | Own richer editing semantics and platform-specific implementation |

The rows summarize the primary evidence and qualifications in the sections below;
none is a production compatibility certification.

### 1. Tiptap core, backed by ProseMirror

Tiptap's MIT editor exposes nodes, marks, attributes, commands and transaction
hooks through extensions. ProseMirror's schema constrains legal document content
and nesting. **Fit inference:** we can describe our supported body deliberately,
store a Draft Asset ID on a custom inline node, and reject unsupported content
instead of accepting an unrestricted document editor's format.
[MIT license](https://github.com/ueberdosis/tiptap/blob/main/LICENSE.md),
[extensions](https://tiptap.dev/docs/editor/core-concepts/extensions),
[ProseMirror schema](https://prosemirror.net/docs/guide/#schema).

StarterKit includes our main block types, the five marks, and undo/redo, while
allowing features to be disabled or configured. Its image extension supports
inline mode but supplies image rendering, not our encrypted asset import system.
Choose a constrained extension set and custom image reference; a stock `src` URL
is not our durable asset contract.
[StarterKit](https://tiptap.dev/docs/editor/extensions/functionality/starterkit),
[image extension](https://tiptap.dev/docs/editor/extensions/nodes/image).

JSON persistence and HTML output are documented; the static renderer supports
custom node/mark mappings. These are useful conversion surfaces, not proof that
our schema round-trips or that output is recipient-compatible email. Keep an
explicit converter to our semantic document and our outgoing-format boundary.
[Tiptap persistence](https://tiptap.dev/docs/editor/core-concepts/persistence),
[static renderer](https://tiptap.dev/docs/editor/api/utilities/static-renderer).

A vanilla JavaScript integration exists, so the WebView does not inherently need
React or React DOM; the native app can own its toolbar. This avoids importing a
web React UI into the native renderer, but does not remove browser editing or
bridge work. Start here rather than raw ProseMirror: the lower-level library
would also leave command wiring and UI assembly to us.
[Vanilla setup](https://tiptap.dev/docs/editor/getting-started/install/vanilla-javascript),
[ProseMirror guide](https://prosemirror.net/docs/guide/).

Core does not require Tiptap Platform. Paid AI, managed documents and other Pro
features have separate terms and service dependencies. The first evaluation
needs none of them. The latest-release endpoint resolved to **v3.31.4** during
this research; pin the evaluated release and its extension versions.
[Platform/core distinction](https://tiptap.dev/pricing),
[release](https://github.com/ueberdosis/tiptap/releases/tag/v3.31.4).

### 2. TenTap as a mobile integration option

TenTap is an MIT React Native editor built around Tiptap in a WebView, with
native toolbar/keyboard integration. Its bridge accepts HTML or JSON initial
content, and `customSource` permits a custom HTML bundle. This could save mobile
integration work while retaining a Tiptap schema we also use on Mac.
[Repository and license](https://github.com/10play/10tap-editor),
[bridge API](https://10play.github.io/10tap-editor/docs/api/useEditorBridge).

However, the **v1.0.1 native podspec declares iOS**, not macOS. A dependency on
React Native WebView does not establish a working TenTap Mac package. Treat it
as a mobile adapter evaluation, with a separate Mac host spike or adaptation.
The latest release found was v1.0.1, published 2025-11-27; this records release
cadence, not a conclusion that the project is abandoned.
[Tagged podspec](https://github.com/10play/10tap-editor/blob/v1.0.1/tentap.podspec),
[release](https://github.com/10play/10tap-editor/releases/tag/v1.0.1).

Its `onChange` notification and asynchronous `getJSON`/`getHTML` retrieval are
separate, and its documentation suggests debouncing. **Integration requirement:**
define revision ordering and an acknowledged flush before closing or switching
Drafts. Do not equate “change callback fired” with “this exact edit was durably
saved.” Also prove custom-source bundling and dependencies on our exact mobile
versions. [Bridge API](https://10play.github.io/10tap-editor/docs/api/useEditorBridge),
[our save behavior](../drafts.md).

### 3. Lexical

Lexical is an MIT web editing framework with a contenteditable root, immutable
editor state and optional packages. Applications supply toolbars, menus, styling
and storage. That is attractive for a focused email composer and our own
assistance controls, but less turnkey than BlockNote. It does not offer a
React-Native-rendered view merely because `@lexical/react` exists.
[Introduction](https://lexical.dev/docs/intro),
[license](https://github.com/facebook/lexical/blob/main/LICENSE).

Custom nodes and serializable properties can represent an inline asset reference;
HTML import/export and JSON serialization are separate facilities. The rich-text
package provides heading and quote nodes; other capabilities are composed from
packages. **Fit inference:** viable, but it requires a semantic adapter and input
behavior work just as Tiptap does. Its DOM-like node structure differs from
ProseMirror's mark model, so conversion effort should be compared using real
Draft fixtures rather than assumed equal.
[Nodes](https://lexical.dev/docs/concepts/nodes),
[serialization](https://lexical.dev/docs/serialization),
[rich-text package](https://lexical.dev/docs/packages/lexical-rich-text).

The latest-release endpoint resolved to **v0.52.0**. Rolling docs identify the
v0.51 custom-node serialization-schema API as experimental and changeable
without deprecation. Pin versions and avoid making an experimental representation
our permanent storage contract.
[Release](https://github.com/facebook/lexical/releases/tag/v0.52.0),
[node API stability note](https://lexical.dev/docs/concepts/nodes#creating-custom-nodes-with-a-serialization-schema).

**Lexical iOS is a different option:** a Swift/TextKit MIT project targeting
iOS 13+, whose README describes it as pre-release without a support guarantee.
It is not evidence of a ready React Native or native Mac adapter. Adopting it
would require native integration and a separately qualified Mac path.
[Lexical iOS status and requirements](https://github.com/facebook/lexical-ios).

### 4. Native options

**Enriched HTML** (`react-native-enriched-html`, formerly
`react-native-enriched`) uses native editing on iOS/Android and documents a Web
implementation. It requires React Native's New Architecture; its compatibility
matrix includes RN 0.86 and 0.81 for the 1.1.x line. That makes it relevant to our
mobile host, but RN-version compatibility does not imply native macOS support.
The project is MIT licensed.
[Official documentation](https://docs.swmansion.com/react-native-enriched-html/),
[compatibility matrix](https://docs.swmansion.com/react-native-enriched-html/misc/compatibility/),
[repository](https://github.com/software-mansion/react-native-enriched-html).

Its documented single-level lists and fixed HTML tags limit general document
mapping; image APIs use a path/URL `src`, which must not silently replace our
stable asset identity. Evaluate preservation of every currently valid Draft;
list nesting is a concern only where our schema permits it. HTML import/export
alone does not prove fidelity. A Mac implementation or different Mac editor is
still needed. Version **1.1.1**, released 2026-08-14, was the latest release found.
[Known limitations](https://docs.swmansion.com/react-native-enriched-html/misc/known-limitations/),
[inline images](https://docs.swmansion.com/react-native-enriched-html/rich-text-formatting/inline-images/),
[repository releases](https://github.com/software-mansion/react-native-enriched-html/releases).

**Enriched Markdown** is a different package, not the Mac version of Enriched
HTML. Its tagged v1.1.1 input docs support headings 1–6 and nested lists, despite
an older roadmap suggesting otherwise. They explicitly exclude code blocks,
tables and blockquotes, and the supported inline-style list lacks inline code.
Its native macOS guide supports input but says VoiceOver accessibility is
stubbed pending NSAccessibility. Therefore it does not currently cover our
composer requirements; rendering rich Markdown is not equivalent to editing all
of it. Markdown-to-semantic fidelity and inline asset editing also need proof.
[Tagged input contract](https://github.com/software-mansion/enriched-markdown/blob/v1.1.1/docs/INPUT.md),
[tagged Mac limitations](https://github.com/software-mansion/enriched-markdown/blob/v1.1.1/docs/MACOS.md).

**RichTextKit** offers SwiftUI wrappers around UITextView/NSTextView and image
attachments under MIT. It could inform a native bridge, but its maintainer
explicitly questions the library's future direction after OS 26's rich TextEditor.
Do not select it as a new core dependency without resolving maintenance needs.
Apple text controls remain an alternative to adopting another editor framework.
[Maintainer's README](https://github.com/danielsaidi/RichTextKit).

A custom native approach retains responsibility for semantic editing,
selection/undo and document conversion inside host components. **Recommendation:**
keep the existing composer as the comparison baseline; native keyboard integration
is a reason to evaluate this path, not proof that it already satisfies every
interaction. Our repository explicitly distinguishes component-test evidence
from native keyboard and accessibility qualification.
[Current composer validation and limitations](../drafts.md).

## Other alternatives: why not first

- **Slate / Plate:** Slate offers a customizable editor model; Plate supplies
  plugins and optional React UI. Their core repositories use MIT licenses.
  They are credible web candidates, but the documented integrations do not
  eliminate our WebView, semantic mapping or native qualification work. No
  project-specific advantage found justifies another web-engine spike.
  [Slate](https://docs.slatejs.org/),
  [Slate license](https://github.com/ianstormtaylor/slate/blob/main/License.md),
  [Plate installation](https://platejs.org/docs/installation),
  [Plate license](https://github.com/udecode/plate/blob/main/LICENSE).
- **Quill:** BSD-licensed browser editor with a Delta format for text, attributes
  and embeds. Possible, but it introduces another document representation and
  custom embed mapping without resolving native hosting. Deprioritize for this
  specific schema-focused evaluation, not because Delta is incapable.
  [Quickstart](https://quilljs.com/docs/quickstart),
  [Delta](https://quilljs.com/docs/delta),
  [license](https://github.com/slab/quill/blob/main/LICENSE).
- **CKEditor 5 / TinyMCE:** commercial-support candidates if buying polished
  web editing and email features becomes the goal. CKEditor documents email
  configuration and inline-style export, including premium components. Both
  current licensing guides offer GPL-2.0-or-later or commercial routes; commercial
  distribution and self-hosting terms need package-specific review. Neither
  eliminates our native host and semantic-storage integration. TinyMCE documents
  fully self-hosted operation without internet, while online trial keys require
  network validation: do not conflate a trial with the production offline path.
  [CKEditor email editing](https://ckeditor.com/docs/ckeditor5/latest/features/email-editing/email.html),
  [CKEditor licensing](https://ckeditor.com/docs/ckeditor5/latest/getting-started/licensing/license-and-legal.html),
  [TinyMCE licensing and deployment](https://www.tiny.cloud/docs/tinymce/latest/license-key/).

## Integration rules and decision tests

Recommendation: package all editor code locally; allow no cloud editor service,
remote asset resolver, or vendor AI by default. The app should own Draft revisions,
asset authorization and persistence. Only approved display data crosses the
bridge; credentials, keys and original attachment bytes stay native. These are
our requirements, not a claim that a selected library enforces them automatically.
[Draft ownership](../drafts.md), [assistance boundary](../domain/assistance.md).

Generic editor HTML output is not MIME delivery. Our Inline Image definition
requires a MIME part; CID mapping, plain-text alternatives and recipient rendering
belong to the existing [Outbox delivery boundary](../outbox.md). A new editor must
preserve that behavior; recipient-client validation remains an evaluation gate.
Keep outgoing serialization from the semantic document,
even if an editor's serializer helps implement it. Also keep quoted correspondence,
recipients and subject outside arbitrary body transformations.
[Delivery terminology](../domain/messages-and-delivery.md),
[assistance scope](../domain/assistance.md).

Run the same small corpus and native journeys against the current composer and
Tiptap first; add Lexical only if a concrete Tiptap-specific limitation or measured
conversion advantage justifies it. General WebView failures in native keyboard,
accessibility or host behavior call for evaluating the native approach instead:

1. **Every host:** local launch/offline use on iPhone, iPad and AppKit Mac; no web
   React packages in native bundles; proper focus, resizing and teardown.
2. **Document fidelity:** all supported blocks/marks, empty paragraphs, mixed
   formatting, Unicode, image positions/IDs, paste normalization and undo/redo.
   Reopen the saved semantic document and compare meaning, not just screenshot.
3. **Native editing:** software/hardware keyboards, IME, dictation, selection
   handles, VoiceOver, shortcuts, iPad split view and Mac menu/undo integration.
4. **Durability/privacy:** type during save/import, fail saving, switch/close,
   reopen, race two Mac windows, remove the account, reject stale assistance.
   Observe actual network requests and reject unwanted plaintext persistence.
5. **Delivery and cost:** recipient-client rendering with inline MIME images;
   measure shipped size, launch time, memory and typing responsiveness on the
   same devices. Record necessary patches and maintenance ownership.

Adopt only if semantic fidelity, durability and native usability pass without a
large editor fork. No dependencies were installed and no editor, native build,
accessibility, performance, delivery or network-isolation tests were run for this
research. Licensing notes summarize sources and do not resolve distribution terms
for a future chosen package set.

## Approved evaluation tickets

The approved evaluation is tracked separately from adoption:

1. [Local Draft editing on all hosts (#818)](https://github.com/unwired-dev/product/issues/818).
2. [Formatted Draft fidelity and reopening (#819)](https://github.com/unwired-dev/product/issues/819).
3. [Private Inline Images (#820)](https://github.com/unwired-dev/product/issues/820).
4. [Save ordering and conflict copies (#821)](https://github.com/unwired-dev/product/issues/821).
5. [Native usability and performance (#822)](https://github.com/unwired-dev/product/issues/822).
6. [Evidence-based adoption decision (#823)](https://github.com/unwired-dev/product/issues/823).
