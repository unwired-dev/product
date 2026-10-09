# On-device assistance

[Domain index](../../GLOSSARY.md) · [behavior notes](../product/assistance.md)

Explicit on-device assistance remains part of the replacement. Profile-specific
terms also describe prototype or follow-up behavior; platform and launch scope
come from the accepted replacement decisions.

Each term has one canonical definition in this glossary collection. Use the
[documentation index](../README.md) and
[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
for launch scope; a term's presence does not establish implementation or release.

## Language

**On-Device Mail Assistance**:
Explicitly requested help for composing, responding to, understanding, or transforming mail through Apple system models on a trusted device, with no cloud or product-backend model fallback.
_Avoid_: Email assistant, background AI processing, cloud inference

**Mail Assistance Enablement**:
A device-local opt-in scoped to one Product Account and Mail Profile that permits explicit On-Device Mail Assistance actions and **Background Message Summaries**. It defaults off independently on every device, starts no inference by itself other than Background Message Summaries, and is cleared when the Product Account is removed.
_Avoid_: Synchronized AI preference, automatic assistance, background enablement

**Assistance Context**:
Compose Assistance admits only the authored Semantic Message Document, current selection, separate subject, and parsed To/Cc display names. Response Assistance admits the authored reply, parsed To/Cc display names, and already-local Thread message text. Understanding Assistance admits only already-local Thread message text; none admits Bcc identities or raw recipient addresses.
The size-bounded, already-local Draft, selection, recipient-display, and Thread text explicitly admitted to one On-Device Mail Assistance operation. It excludes provider fetches, attachments, Inline Images, Remote Message Content, Contacts, Calendar data, and unrelated correspondence.
_Avoid_: mailbox context, account history, implicit retrieval

**Assistance Preview**:
Ephemeral generated or transformed content that remains separate from provider mail and saved Draft content until explicit acceptance and becomes unusable when its Mail Profile or source input revision changes.
_Avoid_: generated Draft, automatic edit, model memory

**Compose Assistance**:
Subject suggestions read the authored body and preview a separate subject, accepted only through the explicit Use Subject action; body drafting, proofreading, and rewriting remain limited to the authored body or current selection.
Explicitly requested, device-local help with a Draft: subject suggestion, body drafting, mechanical proofreading, or meaning-preserving rewriting. Its ephemeral refinement transcript and preview remain outside the editor until explicit acceptance, and it cannot change recipients, signatures, quoted correspondence, attachments, or delivery state.
_Avoid_: automatic rewrite, generated signature, inferred recipient, automatic send

**Response Assistance**:
Explicitly requested, device-local reply options built from an authored Reply or Reply All Draft, parsed recipient display names, and already-local Thread message text. It offers three distinct concise directions and one full contextual reply, opens every choice as an identified editable preview, and provides a read-only source-linked check of addressed and unresolved questions or requests. It never fetches missing content or changes recipients, quoted correspondence, attachments, or delivery state; acceptance is one undoable Draft edit and never sends.
_Avoid_: automatic reply, authoritative completeness claim, automatic send

**Understanding Assistance**:
An explicitly requested, device-local, ephemeral, source-linked summary of already-local Thread message text within one Mail Profile, including supported actions, open questions, stated or inferred dates, and stated deadlines. It excludes attachments, Inline Images, Remote Message Content, unrelated correspondence, Product Sync, and Drafts; discloses omitted content; never fetches a missing body; and becomes stale when its local Thread sources change.
_Avoid_: authoritative summary, background Thread analysis, full-Thread claim

**Background Message Summary**:
A device-local summary of one message's new content, created without a per-message request while **Mail Assistance Enablement** is on and shown in **Catch Up**. It is the only assistance that runs without an explicit request; it is stored only in the device's encrypted cache beside its message, deleted with it, and never synchronized. Planned; see [Catch Up](../catch-up.md).
_Avoid_: Thread summary, cloud summary, synced summary

**Translation Assistance**:
An explicitly requested Apple Translation framework operation over one already-local message body or Draft selection. Incoming translations remain beside the original as non-authoritative text; Draft translations replace only the reviewed selection after explicit acceptance as one undoable edit. Language downloads use the system permission flow, and unsupported, failed, cancelled, stale, or rejected operations leave the source unchanged.
_Avoid_: automatic translation, cloud translation, translated provider content
