---
status: accepted
---

# Use provider-hosted Drafts for cross-client editing

## Context

In the 2026-10-24 feature-gap interview, the product owner explicitly chose
editable provider-hosted Drafts for all launch providers, including Drafts begun
in other mail clients. The earlier product-owned Drafts used end-to-end encrypted
Private Sync for their content and assets, leaving provider Drafts read-only.
Those choices do not provide the requested cross-client continuation.

## Decision

Use the provider's Draft as the canonical synchronized copy for Gmail, Microsoft
mail and IMAP/SMTP connections. Replace Private Sync transport of Draft content
and assets with provider synchronization, retaining encrypted device-local copies
for offline edits and pending uploads. The
[confirmed launch requirements](../product/power-user-launch.md#confirmed-scope-additions-from-2026-10-24)
own lossless editing, known-version conflict preservation, remote send/delete
recovery, automatic verified migration and Draft/Outbox transitions.

The owner accepts that the Mail Provider receives readable Draft content before
sending. This gives compatible external mail clients access to the same Drafts,
at the cost of the earlier end-to-end encrypted product-only Draft transport.
Readable Draft content and provider credentials still never enter the product
backend. Other Private Sync data keeps its existing encryption requirements.

Preserve originating-device Outbox ownership, required content-free atomic send
admission and unknown-outcome safety under
[ADR 0062](0062-keep-queued-delivery-on-its-originating-device.md). Provider Draft
retirement and Undo must preserve content through interrupted transitions. The
decision creates neither a global send lock across other mail clients nor a
guarantee to recover versions those clients never expose.

## Supersession and retained scope

This decision supersedes Draft content and asset transport through Private Sync
in [ADR 0025](0025-use-semantic-rich-text-drafts-with-encrypted-assets.md),
[ADR 0059](0059-replace-the-client-for-a-shared-cross-platform-product.md) and
[ADR 0062](0062-keep-queued-delivery-on-its-originating-device.md), and the earlier
provider Draft read-only boundary. Their historical mechanisms remain recorded.
Formatting restrictions cannot limit the accepted lossless editing requirement;
this decision chooses no replacement editor, storage schema or provider protocol.
HTML/MIME encoding may change, while message sanitization and remote-content
safety remain required.

Provider mail authority does not authorize cross-device delivery takeover or
weaken account, Profile, connection, credential, deletion or transport boundaries.
It does not change Mail Templates or establish future Scheduled Send behavior.

## Status and qualification

This is a user-authorized target, not an implementation or qualification claim.
Runtime work remains pending. Existing Private Sync
Draft behavior and editor evaluations remain current implementation evidence,
not proof of provider interoperability, lossless editing or safe migration.
The launch specification owns the required qualification journeys.
