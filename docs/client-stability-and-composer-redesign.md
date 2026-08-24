# Client stability and composer redesign

Status: accepted product and architecture specification; implementation pending.

## Goal

Make mail reading, Settings, and composing remain responsive while provider and rendering work continues. Reopening valid cached content must avoid provider and remote-host requests. The redesign keeps the existing Apple-first three-column mail model while clarifying hierarchy, reducing decorative containers, and making the composer a first-class editor inside the mail shell.

## Current diagnosis

The current implementation has several coupled causes rather than one loading defect:

- `RemoteMessageContentLoadGate` and the image load gate serialize work through one acquired flag, so unrelated message and image requests wait behind one another.
- Message-body loading contributes to account-wide busy state, allowing read-only work to disable unrelated navigation and actions.
- `MailShellMessageBody` can show cached plain text before replacing it with sanitized HTML in `MessageHTMLWebView`, creating the reported style blink.
- Remote image results are presentation-scoped in memory, so leaving and reopening a message repeats requests even when the person already authorized and viewed the content.
- Settings is presented through app-level and mail-shell sheets instead of independent platform navigation, creating duplicated presentation ownership around the failing entry path.
- Composer presentation is selected by parent sheet or full-screen modifiers while expansion mutates child state, so the visible expand control cannot reliably change the host presentation.
- Composer scrolling is divided between a fixed editor and a lower details scroll view, rather than one document-like scroll surface.
- Recipient completion is pointer-oriented and does not provide the required token, validation, deduplication, and keyboard contract.
- The semantic document supports Markdown conversions, but the live editor does not consistently reveal the converted heading style as one atomic edit.

These findings define implementation starting points, not permission to preserve the current ownership boundaries.

## Product contract

### Nonblocking mail work

Message-body loading, decryption, sanitization, HTML preparation, inline-image loading, authorized remote-image loading, prefetch, and historical backfill are read-only work. None creates global busy state or disables navigation, Settings, composing, or actions on already available mail. Progress is local to the resource or explicit operation it describes.

A Product Account owns a priority-aware coordinator with these starting limits:

- Four concurrent message-body pipelines account-wide
- Two message-body pipelines per Mailbox Connection
- Six concurrent remote-image requests per open message
- Twelve remote-image requests account-wide
- One speculative prefetch or historical lane per connection
- One shared task for duplicate requests for the same stable message or remote resource

A provider may lower only its own connection limit when its transport cannot safely multiplex. It cannot serialize another Mailbox Connection. Interactive work overtakes queued speculative work.

### Fully expanded, viewport-first Threads

The conversation reader remains newest-first with every message expanded. Loading order is:

1. Bodies intersecting the current viewport
2. Bodies nearest the viewport
3. Remaining Thread bodies by distance until the Thread is ready
4. Speculative work outside the selected Thread

Scrolling reprioritizes immediately. Inline and remote images begin only when their message enters the viewport or a one-viewport prefetch margin.

Each unloaded message retains a stable message-shaped placeholder. Resolving content preserves the topmost visible message and its text offset, especially when content above the viewport changes size. A visible body reveals once beneath its anchored header without cross-fading or first showing a differently styled plain-text representation.

### Cache correctness

A valid body-cache hit renders without a provider request or revalidation. Body presentation is invalidated only by:

- A provider-reported message revision or stable-identity change
- A sanitizer, security, or renderer version change
- Explicit cache clearing
- Explicit Reload

Read state and provider metadata continue synchronizing independently and do not invalidate the body.

Authorized, successful, non-tracking remote image bytes and their sanitized presentation mapping use a separate 250 MB device-wide encrypted cache. The quota is shared, but entries are independently namespaced and encrypted by Product Account, Mail Profile, Mailbox Connection, stable message identity, and resource revision. Cross-Profile deduplication is prohibited.

The remote-content cache:

- Survives app relaunch
- Reopens without a remote-host request
- Evicts least-recently-used entries first
- Protects content currently displayed
- Does not consume the 500 MB body-cache budget
- Becomes inaccessible under Profile Lock
- Follows existing Profile-removal deletion rules
- Can be removed with Clear Remote Content in Privacy & Data Settings

Changing remote-content policy to Never hides retained images immediately but does not delete their encrypted bytes. Restoring permission may reuse unchanged cached content without a network request. A cache entry never authorizes fetching changed content, another resource, or another message.

Known tracking pixels remain blocked. Remote requests retain the existing cookie-free, credential-free, public-destination and redirect validation boundary.

### Loading and error presentation

The global loading spinner and blocking loading overlay are removed.

- A cold Thread list uses localized row-shaped skeletons.
- A cold message uses a stable message-shaped placeholder.
- Cached content remains visible during synchronization.
- Mailbox synchronization appears as passive per-connection status.
- A resource failure appears inline beside that mailbox or message with Retry.
- Explicit destructive or delivery operations may show their own local progress and temporarily disable only conflicting controls.

### Reader design

The detail column is one flat scroll surface. It presents the subject and Thread summary first, followed by every expanded message. Each message uses a compact sender and date header, disclosed recipient details, its body, and a thin separator. Thread actions live in one fixed toolbar instead of being repeated for every message.

HTML presentation is prepared off the main actor and committed once when its sanitizer and style configuration are ready. Later image availability updates the existing document without reloading navigation, changing typography, or resetting scroll position. Plain text is a terminal fallback only when HTML cannot be rendered.

### Settings

Settings owns navigation state independently from mailbox work and composing:

- Mac and Catalyst use a dedicated native Settings window opened from Settings or `Command-,`.
- Regular-width iPad uses an in-app two-column Settings workspace.
- iPhone and compact-width iPad push a one-column Settings list into the existing navigation stack.

The Settings shell opens immediately from local state, including while bodies and images load. If one destination cannot load or save, that detail pane keeps its existing values, shows a concise inline error with Retry, and leaves every unrelated destination usable.

The implementation must first reproduce the current Settings-open failure and retain a regression test for its cause. Replacing sheet ownership does not by itself prove the original error fixed.

### Composer presentation and navigation

Composing is mail-shell navigation state, never a sheet or full-screen cover.

On regular-width iPad, Mac, and comparable layouts, the composer starts as a bottom-anchored overlay entirely inside the detail column. It spans the column with 12-point outer insets and uses 70 percent of available height, clamped from 420 through 720 points. The sidebar and Thread list remain interactive; the covered detail column does not. Changing Thread selection updates the reader behind the composer without changing its Draft.

The composer has two states only:

- Detail-column overlay
- Full-app expanded editor

The direct expand or collapse control remains visible beside the overflow menu in both regular-width states. Compact iPhone pushes the editor into the current navigation stack and omits that control because the editor already fills its destination. Expansion preserves document identity, selection, focus, undo history, and autosave state.

The legacy synchronized partial/full opening preference is retired. Expansion is transient to the current editor; later Drafts start from their platform-defined state. Stored preference values are ignored after migration and removed only after the minimum-client generation fences out older clients.

Each mail window has one active composer. Starting another message or selecting another product-authored Draft autosaves and parks the current Draft, then reuses the editor for the requested Draft. Selecting a product-authored Draft enters editing directly; there is no read-only Draft state.

The leading `x` has the accessibility label “Close Composer.” It closes only after the latest autosave succeeds and never discards the Draft. Discard is a separate destructive overflow action. A save failure blocks closing or switching and remains visible inline.

### Composer structure

Only the compact header remains fixed. It contains:

- Leading `x`
- Left-aligned Draft title
- Direct expand or collapse control on regular width
- Overflow menu
- Trailing Send action

From, To, optional Cc and Bcc, subject, formatting controls, authored body, assets, quoted content, and save or error status participate in one outer scroll. The body editor grows with the document and does not own a competing vertical scroll.

To is always visible. “Cc/Bcc” reveals both optional fields; after either receives a recipient, both remain visible with that Draft across autosave, reopen, Product Sync, and layout changes. Reply All reveals populated optional fields automatically.

### Recipient completion

To, Cc, and Bcc show suggestions directly beneath the active field from recent local correspondents and permissioned Apple Contacts. Recipient addresses and queries never pass through the product backend.

Suggestions support pointer, touch, Up Arrow, Down Arrow, Return, and Tab. Acceptance creates a validated removable name-and-address token. Duplicate addresses across To, Cc, and Bcc are rejected with the local message “Already added.”

Comma, semicolon, Return, Tab, or leaving a field asks the mail parser to tokenize manual input. Invalid text remains editable with an inline explanation and blocks Send.

### Rich editor and Markdown input

The authored body retains native spelling, autocorrection, and predictive text. Markdown is an input shortcut over the Semantic Message Document, not the stored or delivered format.

At the start of a body block, typing `# `, `## `, `### `, `- `, `1. `, `> `, or triple backticks atomically removes the marker and applies Heading 1, Heading 2, Heading 3, Bulleted List, Numbered List, Quote, or Code Block. The visual style appears in the same edit without an intermediate state. One Undo restores the literal marker. Pasted Markdown remains unchanged unless explicitly converted.

### Slash Command Menu

Typing `/` as the first non-whitespace character in a body block opens the menu. Following text filters commands. Up Arrow and Down Arrow change selection; Return or Tab applies; Escape or deleting `/` closes. Applying a command removes the slash query.

The first-release catalog is:

- Text
- Heading 1
- Heading 2
- Heading 3
- Bulleted List
- Numbered List
- Quote
- Code Block
- Ask Compose Assistance…
- Draft from Prompt
- Rewrite Selection
- Proofread
- Shorten
- Change Tone
- Suggest Subject

Heading 4, To-do List, Toggle List, Page, and Callout are excluded because the interoperable message document does not define their semantics.

On regular width, the menu is 320 points wide, anchored to the caret, and flips above it when necessary. On iPhone, it clamps to the composer width and keyboard-safe area rather than becoming a sheet. It may scroll internally, follows system appearance, highlights one command, and retains editor focus until a command is chosen.

### Compose Assistance

Generative writing never starts or appears automatically while typing. Selecting an assistance command replaces the slash menu with an anchored, nonmodal panel inside the composer. The panel contains the prompt or command options, Cancel, and Generate. Progress remains local to the panel while the Draft stays scrollable and editable.

- Ask Compose Assistance uses the selection when present and otherwise only the authored body.
- Draft from Prompt previews insertion at the caret and never overwrites existing text automatically.
- Rewrite Selection, Proofread, Shorten, and Change Tone require selected text.
- Suggest Subject reads the authored body and previews a separate subject.
- Every result requires explicit Insert, Replace, or Use Subject.
- Dismissal changes nothing and destroys the preview.

Existing on-device, privacy, input-bound, fact-preservation, and no-automatic-send rules remain unchanged.

### Visual system

The redesign is Apple-native and content-first, respects the device's System, Light, or Dark appearance preference, and uses:

- Flat mail lists and reading surfaces with separators instead of nested cards
- One restrained accent color for selection and primary actions
- Labeled status where color is never the only indicator
- Native typography, Dynamic Type, control sizing, and comfortable hit targets
- Translucent material only for genuinely floating controls and the composer overlay
- Three stable columns at regular width and native navigation collapse at compact width

The regular-width sidebar orders active Profile and search, Compose, primary Unified Mailboxes, secondary mailboxes, collapsible connection folders and labels, then a fixed Settings entry. Synchronization and authorization issues appear beside the affected connection.

Thread rows preserve the sender, subject, then preview hierarchy. The new-user default is comfortable density with one preview line. Existing compact/comfortable/spacious density and zero-through-three-line preview preferences remain supported and retain saved values. Unread state uses stronger sender and subject weight plus a non-color-only accent indicator. Real contact photos may appear; generated initials avatars are excluded.

The attached Notion screenshot is a behavioral reference for command discovery and filtering, not a visual design to copy.

## Implementation boundaries

### Loading and caching

- Replace one-at-a-time load gates with a Product Account-owned coordinator actor.
- Keep resource state keyed by stable message or remote-resource identity; do not project it into account-wide interface busy state.
- Make in-flight deduplication explicit and cancellation consumer-aware.
- Keep provider adapter limits below the coordinator boundary so one constrained transport cannot affect another.
- Persist sanitized body presentation and authorized remote-content metadata with versioned cache keys and atomic replacement.
- Separate cached authorization reuse from permission to perform a new request.

### Rendering

- Build one immutable, render-ready message presentation before revealing a cold body.
- Keep the SwiftUI view tree stable while readiness changes.
- Update remote-image resources inside the existing document rather than replacing its web view.
- Own viewport-priority and scroll-anchor bookkeeping at the Thread reader, not inside independent message views.

### Settings

- Remove duplicate app/mail-shell Settings presentation state.
- Give the Mac Settings window and in-app Settings destinations one router contract.
- Retain the typed destination registry and Profile-scoped stores.
- Make destination loading independent and retain the last valid snapshot on failure.

### Composer and editor

- Move composer ownership from presentation modifiers into the mail-shell navigation model.
- Reuse one composition identity across overlay, expansion, compact navigation, and adaptive-layout changes.
- Use one outer scroll and a rich native text-system bridge capable of intrinsic document growth, caret geometry, selection retention, native text assistance, semantic attributed editing, and keyboard command routing.
- Keep recipient suggestions, slash commands, assistance previews, and validation as explicit editor-adjacent state rather than encoding them in the Draft document.

## Delivery sequence

### 1. Stability foundation

- Add regression coverage for concurrent distinct-message loading, same-resource deduplication, cache hits, image reuse after relaunch, policy changes, and Settings opening during mail work.
- Replace global body/image gates and remove read-only work from account-wide busy state.
- Add the Authorized Remote Content Cache and Storage Settings controls.
- Commit render-ready bodies once and remove the global spinner.
- Reproduce and repair the current Settings-open error while moving presentation to the accepted platform destinations.

### 2. Composer shell

- Move composing into mail-shell navigation state.
- Implement regular overlay, full-app expansion, compact push, direct controls, and adaptive state preservation.
- Implement one outer scroll, save-and-close, explicit discard, one composer per window, and direct Draft editing.
- Remove the replaced sheet, full-screen-cover, and legacy presentation-preference paths after callers migrate.

### 3. Editing intelligence

- Add recipient suggestions, keyboard navigation, parser-backed tokens, deduplication, and inline validation.
- Stabilize semantic Markdown transformations and Undo.
- Add the Slash Command Menu and context-eligible Compose Assistance panel.
- Retain native spelling, autocorrection, predictive text, selection, and accessibility behavior.

### 4. Visual redesign

- Apply the accepted sidebar, Thread-row, reader, composer, and Settings hierarchy.
- Replace nested decorative cards with semantic lists, sections, dividers, and restrained floating material.
- Verify real-content edge cases at compact and regular widths rather than only empty or short previews.

### 5. Release gate

- Run performance, accessibility, privacy, cache-migration, mixed-version, and cross-platform regressions.
- Remove temporary compatibility code only after its callers and synchronized preference generation migrate.
- Ship no long-lived duplicate loading, Settings, composer, or editor systems.

## Acceptance checks

### Loading and caching

- Two uncached messages on one capable connection overlap without exceeding two body pipelines.
- Distinct connections load concurrently without exceeding four account-wide body pipelines.
- Same-message requests share one provider operation and one cache write.
- A valid cached body reopen performs zero provider body requests.
- An unchanged authorized remote image reopen after app relaunch performs zero remote-host requests.
- Switching policy to Never hides cached images without deleting them; restoring permission reuses unchanged bytes.
- Clear Remote Content removes only its scoped local cache and never provider mail.
- Settings, navigation, composing, and available mail actions remain responsive under saturated body and image limits.

### Rendering and reader

- A cold HTML body never appears first as differently styled plain text.
- Body readiness produces one reveal and does not recreate the surrounding reader.
- Every Thread message remains expanded.
- Visible bodies start before off-screen bodies, and scrolling reprioritizes deterministically.
- Loading content above the viewport preserves the visible message and text offset.
- Remote images update without resetting typography or scroll position.
- No global loading spinner or blocking loading overlay remains.

### Settings

- Settings opens during body, image, prefetch, and backfill work on iPhone, iPad, and Catalyst.
- Catalyst Settings and `Command-,` reuse one dedicated Settings window contract.
- A failed destination retains prior values, shows inline Retry, and leaves other destinations usable.
- A regression test reproduces the original Settings-open failure before proving the repair.

### Composer and editor

- Regular-width compose begins inside the detail column; expansion fills the full app and collapse restores the same editor state.
- Compact iPhone compose is pushed and never appears as a sheet.
- The full composer content uses one outer vertical scroll and the body has no nested vertical scroll.
- The `x`, expansion control, overflow, left-aligned title, and Send action remain directly discoverable as specified.
- Closing, switching Drafts, and starting another message preserve saved content; failures block the transition inline.
- Product-authored Draft selection opens directly in edit mode.
- Recipient suggestions and tokens pass pointer, touch, keyboard, validation, and duplicate tests.
- Every Markdown shortcut converts atomically and one Undo restores the literal marker.
- Slash commands pass trigger, filtering, keyboard, touch, dismissal, geometry, and context-eligibility tests.
- Compose Assistance never runs automatically and changes the Draft only after explicit acceptance.

### Design and accessibility

- VoiceOver labels, focus order, keyboard traversal, Dynamic Type, contrast, reduced motion, and 44-point touch targets pass on affected surfaces.
- iPhone, regular-width iPad, and Catalyst snapshots verify hierarchy without relying on color alone.
- Long recipient lists, long subjects, long Threads, large Drafts, empty states, offline state, and localized strings remain usable.

## Verification strategy

- Use Swift Testing for coordinator limits, priority ordering, deduplication, cache keys, eviction, policy transitions, parser/token behavior, Markdown conversion, Draft switching, and router decisions.
- Use existing XCTest UI targets only for platform navigation, pointer/touch/keyboard interaction, focus, accessibility, and visual state that requires UI automation.
- Extend the Release performance fixture to cover a warm cached Thread, viewport-priority scheduling, composer opening, and absence of 100 ms main-thread stalls.
- Add deterministic request counters to synthetic provider and remote-image fixtures so “no provider request” and “no remote-host request” are assertions rather than timing inferences.
- Run Apple format/lint and the affected Debug, Release-performance, and Core Mail Loop gates required by repository policy.

## Related decisions

- [ADR 0012: Use local-first metadata and a bounded encrypted body cache](adr/0012-bounded-encrypted-body-cache.md)
- [ADR 0018: Local mail performance budget](adr/0018-local-mail-performance-budget.md)
- [ADR 0025: Use semantic rich-text Drafts with encrypted assets](adr/0025-use-semantic-rich-text-drafts-with-encrypted-assets.md)
- [ADR 0029: Sanitize HTML before WebKit rendering](adr/0029-sanitize-html-before-webkit-rendering.md)
- [ADR 0052: Keep mail assistance on device and input-bound](adr/0052-keep-mail-assistance-on-device-and-input-bound.md)
- [ADR 0057: Present composing inside the mail shell](adr/0057-present-composing-inside-the-mail-shell.md)
- [ADR 0058: Present Settings as independent navigation](adr/0058-present-settings-as-independent-navigation.md)
- [Settings redesign](settings-redesign.md)
