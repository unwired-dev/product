# On-device assistance: behavior notes

[Vocabulary](../domain/assistance.md) · [Domain index](../../CONTEXT.md)

Explicit on-device assistance remains part of the replacement. Profile-specific
terms also describe prototype or follow-up behavior; platform and launch scope
come from the accepted replacement decisions.

The notes below were moved from `CONTEXT.md` without changing their wording.
They mix retained product constraints with prototype implementation and feature
scope. Read them alongside the accepted ADRs; “v1” and “first release” in these
notes refer to their original feature scope. They do not establish replacement
launch requirements or proof that a feature is implemented.

## Decisions and scope

- [Accepted replacement scope](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Keep Mail Assistance on device and input-bound](../adr/0052-keep-mail-assistance-on-device-and-input-bound.md)
- [Keep Mail Assistance enablement device-local](../adr/0053-keep-mail-assistance-enablement-device-local.md)

[The documentation index](../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Assistance inputs, previews and acceptance

- **Mail Assistance Enablement** is a **Device-Local Preference** scoped to one Product Account and Mail Profile. It defaults off independently on every device, never synchronizes, permits only explicit assistance actions, and remains usable during **Quiet State**
- **Compose Assistance** admits only the authored **Semantic Message Document**, current selection, separate subject, and parsed recipient display identities. It excludes signatures, quoted correspondence, attachments, source Thread content, **Remote Message Content**, and delivery actions; proofreading is mechanical, while every rewrite preserves facts, questions, commitments, dates, amounts, links, quotes, meaning, and surrounding formatting or asks for clarification
- Ask Compose Assistance uses the current selection when present and otherwise only the authored body; Draft from Prompt previews insertion at the caret without overwriting existing text; Rewrite Selection, Proofread, Shorten, and Change Tone require a selection; Suggest Subject reads the authored body and previews a separate subject
- **Compose Assistance** previews and refinements remain ephemeral outside the editor. Dismissal destroys their transcript, source changes invalidate them, and explicit Insert or Replace creates one undoable authored-body edit. Accepted content becomes ordinary encrypted Draft content without an assistance marker and never sends automatically
- **Response Assistance** is explicitly requested from a Reply or Reply All Draft and admits only its authored body, parsed To/Cc display identities, and already-local Thread bodies newest-first within deterministic bounds. It never fetches missing bodies or admits Bcc identities, raw addresses, attachments, **Inline Images**, **Remote Message Content**, Contacts, Calendar data, or unrelated correspondence
- **Response Assistance** returns three distinct concise reply directions and one full contextual reply. Selecting any option opens an identified editable preview rather than inserting it; its read-only answer-completeness check links every explicit question or request to admitted sources and marks it addressed or unresolved without claiming coverage of omitted content
- A Response Assistance result becomes stale whenever the Draft or local Thread sources change. Explicit Use in Draft replaces only the authored body as one undoable **Semantic Message Document** edit; quoted correspondence and delivery state remain unchanged, accepted content has no assistance marker, and nothing sends automatically
- Every slash-menu assistance result requires an explicit Insert, Replace, or Use Subject action
- Selecting a slash-menu assistance command replaces that menu with an anchored, nonmodal composer panel containing its prompt or options, Cancel, and Generate; progress remains inside the panel while the Draft stays scrollable and editable, and dismissal destroys the preview without changing the Draft
- **Understanding Assistance** is explicitly requested, device-local, scoped to one Mail Profile, and admits only already-local source-message text newest-first within deterministic bounds. It excludes attachments, **Inline Images**, **Remote Message Content**, unrelated correspondence, **Product Sync**, and Drafts; links every result item to its supporting messages; and identifies omissions, uncertainty, inferred dates, unresolved questions, and ambiguous responsibility instead of inventing detail
- **Understanding Assistance** results remain ephemeral, are excluded from **Product Sync** and Drafts, and become unusable until regenerated whenever their local Thread sources change
- **Translation Assistance** uses Apple's Translation framework, accepts only an already-local message body or explicit Draft selection, and lets the person correct source and target languages before translating. It distinguishes installed, downloadable, and unsupported device language pairs; a required language download uses the system permission flow and never starts in the background
- An incoming translation remains beside its unchanged original and is explicitly non-authoritative. A reviewed Draft translation replaces only its captured selection as one undoable **Semantic Message Document** edit; accepted text becomes ordinary encrypted Draft content with no provenance marker and never sends automatically. Cancellation, rejection, failure, stale input, Profile Lock, and unsupported language pairs preserve the source

## Profile lock and assistance

- Locking a Profile cancels its On-Device Mail Assistance work and destroys every retained Assistance Context and Assistance Preview; successful reauthentication does not restore a discarded preview
