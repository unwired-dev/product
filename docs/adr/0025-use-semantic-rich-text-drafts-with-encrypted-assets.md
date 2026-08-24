# Use semantic rich-text Drafts with encrypted assets

Draft bodies use a Semantic Message Document shared by Markdown shortcuts, formatting controls, context actions, and standards-compatible HTML plus plain-text delivery instead of storing Markdown or raw HTML. Attachments and inline images synchronize as independently encrypted Draft Assets, trading Product Sync storage and chunk-management complexity for complete cross-device Draft editing without exposing authored content to the backend; documents and assets share the non-evicting 100 MB device-wide Outgoing Content Store with Send Reminders and Scheduled Sends, and Send remains unavailable until every required asset is locally complete and verified. ADR-0046 broadens the original Draft-only storage boundary so transitions between Draft, reminder, and scheduled states reuse the same encrypted assets instead of duplicating them.

Product-authored Drafts have no read-only presentation. Selecting one opens its Semantic Message Document directly in the composer, where every change continues through the existing encrypted autosave and conflict rules.

To, Cc, and Bcc complete from recent local correspondence and permissioned Apple Contacts. Suggestions remain directly beneath the active recipient field and support pointer, touch, arrow-key, Return, and Tab operation. Acceptance produces a validated recipient token and deduplicates the address across all recipient fields.

Manual input uses the mail parser rather than an editor-specific approximation. Comma, semicolon, Return, Tab, or leaving the field attempts to create a removable name-and-address token. Invalid text remains editable with an inline explanation and blocks Send. A duplicate across To, Cc, and Bcc is not added and reports “Already added” beside the active field.

To remains visible by default. A trailing “Cc/Bcc” control reveals both optional fields, and once either contains a recipient both stay visible with that Draft across autosave, reopen, Product Sync, and adaptive-layout changes. Reply All reveals populated optional fields automatically.

The body editor retains native spelling, autocorrection, and predictive text. Typing `/` opens a command picker over the same Semantic Message Document; block commands change semantic structure rather than inserting persistent Markdown. Compose Assistance may also appear in that picker, but every generative operation requires an explicit command and never starts or appears automatically in response to ordinary typing.

The first-release command catalog is Text, Heading 1, Heading 2, Heading 3, Bulleted List, Numbered List, Quote, and Code Block, followed by context-eligible Ask Compose Assistance, Draft from Prompt, Rewrite Selection, Proofread, Shorten, Change Tone, and Suggest Subject actions. Heading 4, To-do List, Toggle List, Page, and Callout stay outside the menu because the interoperable document model does not define their semantics.

The menu opens only when `/` is the first non-whitespace character in a body block, avoiding accidental activation in prose, dates, and URLs. Additional text filters the catalog; arrow keys move selection; Return or Tab applies the selected command and removes the query; Escape or deleting the opening slash closes the menu without transforming content.

On regular-width layouts, the menu is 320 points wide, anchored to the caret, and flips above it when necessary. On iPhone, it clamps to the composer width and keyboard-safe area instead of presenting a sheet. The menu may scroll internally, follows system appearance, highlights one active command, and preserves body-editor focus.

Typed Markdown remains an input accelerator rather than a stored format. At the start of a body block, `# `, `## `, `### `, `- `, `1. `, `> `, and triple backticks immediately remove their marker and apply the corresponding heading, list, quote, or code-block semantics without showing an intermediate style. One Undo restores the literal input, while pasted Markdown remains literal unless the person explicitly requests conversion.

Compose Assistance commands are context-bound and preview-first. Ask Compose Assistance uses the current selection when present and otherwise only the authored body. Draft from Prompt previews insertion at the caret and never overwrites existing text automatically. Rewrite Selection, Proofread, Shorten, and Change Tone require selected text. Suggest Subject reads the authored body and previews a separate subject. Every result remains outside the document until an explicit Insert, Replace, or Use Subject action.

Selecting an assistance command replaces the slash menu with an anchored panel inside the composer rather than a modal presentation. The panel contains the prompt or command options, Cancel, and Generate. Only that panel reports generation progress while the Draft remains scrollable and editable. Dismissal changes nothing and destroys the preview.
