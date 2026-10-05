# Messages and delivery: behavior notes

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](../architecture/product/messages-and-delivery.md).

[Vocabulary](../domain/messages-and-delivery.md) · [Domain index](../../GLOSSARY.md)

The replacement keeps queued delivery on its originating device under
[ADR 0062](../adr/0062-keep-queued-delivery-on-its-originating-device.md).
Scheduled Send Claim and Scheduled Delivery Authorization name the older
cross-device scheduling protocol; their definitions do not authorize takeover
in the replacement.

These observable requirements were separated from the former monolithic glossary
and its implementation notes. The reviewer owns the separate architecture companion
under the [implementation and review workflow](../agents/implementation-review.md).
“v1” and “first release” in these notes refer to their original feature scope.
They do not establish replacement launch requirements or proof that a feature is
implemented.

## Read receipts

- **Read Receipt** preferences distinguish responding to incoming requests from requesting receipts for outgoing messages
- Incoming **Read Receipt** requests default to asking the user every time and are never acknowledged silently
- Outgoing **Read Receipt** requests are off by default

## Conditional Outbox navigation

- **Outbox** is a conditional unified item rather than a permanent mailbox

## Prototype composer presentation

- On regular-width layouts, composing starts as a bottom-anchored, nonmodal overlay contained by the detail column; expanding that composer takes over the entire app surface while preserving the same editor and Draft state
- While that composer is not expanded, the sidebar and Thread list remain interactive, the covered detail column does not, and changing Thread selection updates the reader behind the composer without dismissing or resetting its Draft; closing reveals the latest selection
- The regular-width composer spans the detail column with 12-point outer insets and uses 70 percent of available height clamped from 420 through 720 points; it has only overlay and full-app states, not freeform drag resizing
- On compact layouts, composing is an editor destination pushed into the existing navigation stack rather than a sheet or full-screen modal
- Composer expansion is transient to the open editor and never changes how a later Draft opens; the legacy synchronized partial-or-full opening preference is ignored after migration.
- Selecting a product-authored **Draft** enters that same editor directly; Drafts have no read-only reader state
- Each mail window has one active composer. Its `x` closes only after the latest autosave succeeds and never discards the Draft; Discard remains an explicit destructive overflow action
- Starting another message or selecting another product-authored Draft autosaves and parks the current Draft, then switches the same editor to the requested Draft; a save failure blocks the switch and remains visible inline
- The expand or collapse control remains directly visible in both regular-width states and is absent on compact iPhone, where the composer already fills its navigation destination
- The **Formatting Toolbar Preference** synchronizes globally and hides only the formatting toolbar; Markdown, keyboard, context-menu, document, and delivery formatting remain available

## Provider submission and Draft lifetime

- After SMTP accepts a message for a **Standards-Based Mailbox Connection**, the client appends a verified copy to its mapped Sent role; if that append cannot be confirmed, it retries or reconciles only the sent-copy operation, visibly marks the copy as pending, and never resends the delivered message

- An ambiguous post-content SMTP outcome is never retried automatically and requires explicit user reconciliation
- The **Outbox** appears only while it contains a scheduled, pending, retrying, failed, or needs-attention outgoing message
- Composer edits continuously autosave to an encrypted **Draft**; if the **Outgoing Content Store** cannot admit the latest edit, the composer visibly retains unsaved state and blocks closing, sending, and discard until the edit is saved or explicitly abandoned
- The Apple Share Extension binds explicit shared content to the device-local **Startup Profile** and its Default Sending Identity, authenticates before revealing a locked Profile, and opens the normal composer without a direct-send path or backend-readable copy.
- Sending removes a **Draft** only after the outgoing message is durably admitted to the **Outbox**, which retains its complete content and assets until the attempt becomes terminal or is cancelled.
- **Draft Assets** synchronize through **End-to-End Encrypted Product Sync**. Send remains unavailable until every required asset is complete and valid on the sending device.
- Product-authored Drafts are distinct from provider-hosted Draft mailboxes: provider Draft messages remain read-only provider mail in v1 and are not imported, mirrored, or retired by Product Sync Draft operations
- Discarding a **Draft** or durably admitting it to the **Outbox** preserves the sent or discarded state across devices. A conflicting offline edit becomes a user-visible conflicted Draft copy whose assets remain retained until it is resolved or discarded.

## Historical cross-device scheduling

These prototype rules include delivery takeover by another device.
[ADR 0062](../adr/0062-keep-queued-delivery-on-its-originating-device.md)
supersedes that ownership model for the replacement, including future scheduling.

- A **Scheduled Send** is a synchronized Outbox commitment, while a **Send Reminder** remains attached to a Draft and never authorizes delivery
- A Send Reminder synchronizes end-to-end encrypted; its Draft remains the content authority, and only the current reminder can be opened, cleared or rescheduled.
- The latest active notification-authorized Trusted Device to reconcile a Send Reminder owns its local notification. A later owner fences the prior owner, while offline reminders remain visibly pending and denied or suppressed reminders remain available as overdue Drafts
- Send Reminder interruption is governed by the existing default-on **Return-to-Attention** preference together with device interruption controls, Quiet State, Profile Lock, OS notification authorization, and device-local lock-screen content policy
- Scheduled Send is available for every send-capable new-message, reply, reply-all, and forward composer and uses the same product-owned behavior for every send-capable **Mailbox Connection**
- A Scheduled Send is admitted only after its complete payload synchronizes end-to-end encrypted and its Draft is durably retired; admission fails closed while offline or uncertain and leaves the message as a Draft

- Scheduled Send delivery is best-effort at or after its absolute selected instant; it never promises exact background execution, and an item more than 24 hours late requires user attention instead of sending automatically
- In the prototype, any compatible trusted device with the selected **Mailbox Authorization** and **Scheduled Delivery Authorization** may deliver a Scheduled Send, but exactly one device may proceed to provider handoff.
- Opening a Scheduled Send for editing, rescheduling, cancellation, mode conversion and delivery cannot create duplicate delivery commitments.
- Cancelling a Scheduled Send restores an editable Draft, while cancelling a Send Reminder removes only the reminder; explicit mode conversion keeps exactly one synchronized state active
- Scheduled Send never silently changes its selected Mailbox Connection, and **Send Now** remains subject to the **Undo Send Window**
- Removing authorization from one device preserves Scheduled Sends for other eligible devices; removing their Mailbox Connection everywhere or deleting the Product Account warns and cancels affected commitments

## Authored content and delivery attempts

- The **Outgoing Content Store** has a non-evicting 100 MB device-wide limit shared by Drafts, Send Reminders, Scheduled Sends, and their documents and assets
- Markdown syntax acts as an input shortcut over the **Semantic Message Document** rather than becoming the stored or sent message format
- Typing `# `, `## `, `### `, `- `, `1. `, `> `, or triple backticks at the start of a body block immediately removes the marker and applies the matching heading, list, quote, or code-block semantics without an intermediate style; one Undo restores the literal marker and pasted Markdown remains unchanged unless explicitly converted
- The authored body uses native spelling, autocorrection, and predictive-text behavior
- Typing `/` in the authored body opens the **Slash Command Menu**; its generative entries remain explicit **Compose Assistance** actions and never appear or run automatically while typing
- The v1 **Slash Command Menu** offers Text, Heading 1, Heading 2, Heading 3, Bulleted List, Numbered List, Quote, and Code Block, followed by the context-eligible Ask Compose Assistance, Draft from Prompt, Rewrite Selection, Proofread, Shorten, Change Tone, and Suggest Subject actions
- Heading 4, To-do List, Toggle List, Page, and Callout remain outside the v1 menu because they are not part of the interoperable **Semantic Message Document**
- The **Slash Command Menu** opens only when `/` is the first non-whitespace character in a body block; subsequent text filters commands, Up Arrow and Down Arrow move selection, Return or Tab applies it and removes the slash query, and Escape or deleting `/` closes the menu
- On regular-width layouts, the **Slash Command Menu** is a 320-point caret-anchored menu that flips above the caret when necessary; on iPhone it clamps to the composer width and keyboard-safe area rather than becoming a sheet
- The menu may scroll internally, follows system appearance, highlights one active command, and preserves body-editor focus
- Formatting controls and context actions edit the same **Semantic Message Document**
- A **Mail Template** uses that same semantic vocabulary, never includes recipients, attachments, Inline Images, signatures, or dynamic placeholders in v1, and never sends automatically
- Creating a Draft from a Mail Template retains the Profile's default authorized **Sending Identity**; inserting one leaves an authored subject unchanged
- Outgoing delivery derives interoperable HTML and plain-text alternatives from the **Semantic Message Document**
- The v1 **Semantic Message Document** supports paragraphs, headings one through three, bold, italic, underline, strikethrough, bulleted and numbered lists, blockquotes, inline code, code blocks, links, undo, and redo
- The **Semantic Message Document** may contain **Inline Images** at authored cursor positions
- Font families, arbitrary font sizes, text and background colors, alignment, and tables are outside the v1 formatting vocabulary
- Rich-message delivery is verified against current Apple Mail on iOS and macOS, Gmail web and mobile, and Outlook web and desktop, while every message includes a standards-compatible plain-text alternative
- Pointer right-click, touch long-press, and keyboard context-menu access expose the same current-block choices: paragraph, headings one through three, bulleted list, numbered list, blockquote, and code block; inline styles remain selection-based
- Pasting or dropping image data into the message body creates an **Inline Image**, while choosing an image through the attachment picker creates an **Attachment**; an explicit context action converts either representation to the other
- Before **Outbox** admission, the client computes final transfer-encoded MIME size and enforces a known limit from the selected sending **Mailbox Connection**; an unknown provider limit permits attempted delivery with a visible estimate, while excess size requires removal or local image compression
- During provider delivery, outgoing **Attachments** and **Inline Images** travel from the trusted device to the **Mail Provider** without passing through the product backend; their encrypted Draft Assets synchronize through **Product Sync** before handoff
- The **Undo Send Window** defaults to 10 seconds and may be disabled or set to 20 or 30 seconds
- Cancelling during the **Undo Send Window** prevents provider handoff; the product never describes this as recalling a message already accepted by a provider
- Transiently failed **Outgoing Delivery Attempts** retry automatically with bounded exponential backoff
- Permanently failed **Outgoing Delivery Attempts** stop until the user resolves authentication, policy, recipient, or message problems
- Pending and failed Outbox messages remain editable and cancellable until an **Outgoing Delivery Attempt** has been handed to its provider; an in-flight attempt must first reach a terminal state
- Editing an eligible Outbox message creates a new **Outgoing Delivery Attempt** rather than mutating an attempt already in flight

## Thread identity and reader behavior

- A **Thread** groups related messages without being the categorization target
- A **Thread** never spans multiple **Mailbox Connections**, including when shown in a **Unified Mailbox**
- A **Thread** uses a reliable provider conversation identity when available, otherwise RFC message and reply identifiers
- Subject similarity alone never combines messages into a **Thread**, and messages without reliable linkage remain separate
- Selecting a **Thread** opens its conversation rather than only its latest message
- The conversation reader orders messages newest to oldest and expands every message, with the newest message at the top; bodies intersecting the visible viewport have priority over every off-screen body, with immediate reprioritization when scrolling changes visibility
- The reader uses one flat detail-column scroll with subject and Thread summary first, then compact sender-and-date headers, disclosed recipient details, message bodies, and thin message separators rather than stacked cards
- Thread-level actions remain in one fixed reader toolbar instead of repeating controls on every expanded message
- After visible bodies finish, off-screen bodies load automatically in distance-from-viewport order until the Thread is ready; **Remote Message Content** begins only within the visible viewport or a one-viewport prefetch margin
- An explicit message open resolves every visible, sanitized CID reference for received **Inline Images** within the per-message limits and shared presentation budget, without viewport admission; this applies to #605 under the [ADR 0029 amendment](../adr/0029-sanitize-html-before-webkit-rendering.md#amendment--2026-10-06), while Remote Message Content remains governed by [#763](https://github.com/unwired-dev/product/issues/763)
- As bodies and images resolve, the reader preserves the topmost visible message and its text offset; content resolving above the viewport cannot move what is being read, a visible body reveals once beneath its anchored header without a cross-fade, and images reserve sanitized dimensions when available
- Reply, Reply All, Forward, and the fixed reader toolbar's multi-select Category control target the newest message; Archive, Delete, Move, Spam, **Pin**, **Muted Thread**, and read-state actions target the entire **Thread**

## Sending identities and recipient entry

- Replies and forwards preserve the authorized **Sending Identity** that received the source message
- If the receiving **Sending Identity** is unavailable on the current device, Send remains blocked until the user authorizes it or explicitly chooses another active-Profile identity
- A new message defaults to the Profile's **Default Sending Identity** and always exposes its From address
- To, Cc, and Bcc show **Recipient Suggestions** beneath the active field from recent local correspondence and permissioned Apple Contacts; pointer, touch, Up Arrow, Down Arrow, Return, and Tab can select or accept a suggestion, which creates one validated recipient token without duplicates
- To remains visible, while a trailing “Cc/Bcc” control reveals both optional fields; once either has a recipient, both remain visible for that Draft across autosave, reopen, Product Sync, and adaptive-layout changes, and Reply All reveals populated fields automatically
- For manual entry, comma, semicolon, Return, Tab, or leaving a recipient field asks the mail parser to create a removable name-and-address token; invalid text remains editable with an inline explanation and blocks Send
- A duplicate address across To, Cc, and Bcc is not added and reports “Already added” beside the active field
- Manual valid addresses remain available, and recipient addresses and suggestion queries never pass through the product backend
- Non-secret **Sending Identity** definitions, verification state, and the **Default Sending Identity** synchronize end-to-end encrypted; provider credentials and manual verification codes remain device-local
- Existing primary addresses migrate as provider-confirmed identities, and the legacy **Default Sending Connection** selects the initial default without changing behavior
- The product never silently substitutes a different sending identity
- Unauthorized or receive-only **Mailbox Connections** remain visible but cannot be selected for sending
