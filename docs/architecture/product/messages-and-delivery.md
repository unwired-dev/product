# Messages and delivery: architecture notes

Reviewer-only companion to [docs/product/messages-and-delivery.md](../../product/messages-and-delivery.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

The replacement keeps queued delivery on its originating device under
[ADR 0062](../../adr/0062-keep-queued-delivery-on-its-originating-device.md).
Scheduled Send Claim and Scheduled Delivery Authorization name the older
cross-device scheduling protocol; their definitions do not authorize takeover
in the replacement.

## Decisions and scope

- [Accepted replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Keep queued delivery on its originating device](../../adr/0062-keep-queued-delivery-on-its-originating-device.md)
- [Model Outbox delivery as immutable attempts](../../adr/0016-durable-outbox-delivery-attempts.md)
- [Use semantic rich-text Drafts with encrypted assets](../../adr/0025-use-semantic-rich-text-drafts-with-encrypted-assets.md)
- [Scope verified Sending Identities to Mail Profiles](../../adr/0054-scope-verified-sending-identities-to-mail-profiles.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Prototype composer presentation

- Composer expansion is transient to the open editor and never changes how a later Draft opens; the legacy synchronized partial-or-full opening preference is ignored after migration and removed only after older clients are fenced out

## Provider submission and Draft lifetime

- Before attempting that Sent append, the trusted device encrypts the exact accepted MIME in a connection-scoped journal; a stable RFC Message-ID prevents duplicate appends during recovery, and the journal is removed only after Sent containment or append is confirmed

- The Apple Share Extension binds explicit shared content to the device-local **Startup Profile** and its Default Sending Identity, authenticates before revealing a locked Profile, stores only an encrypted **Share Intake Draft** in the shared App Group, and opens the normal composer without a direct-send path or backend-readable copy

- Sending removes a **Draft** only after the outgoing message is durably admitted to the **Outbox**, which atomically retains the complete rendered MIME payload and referenced Draft Assets until the attempt becomes terminal or is cancelled

- **Draft Assets** synchronize through **End-to-End Encrypted Product Sync** as independently encrypted, verified chunks; Send remains unavailable until every required asset is complete and valid on the sending device

- Discarding a **Draft** or durably admitting it to the **Outbox** writes a synchronized tombstone. If an offline edit conflicts with that tombstone, the tombstone preserves the sent or discarded Draft while the edit is materialized as a user-visible conflicted Draft copy; referenced Draft Assets remain retained until the conflict copy is resolved or discarded, then become eligible for cleanup

## Historical cross-device scheduling

- A Scheduled Send is admitted only after its complete payload synchronizes end-to-end encrypted, its Draft tombstone commits, and its opaque operational schedule is activated; admission fails closed while offline or uncertain and leaves the message as a Draft

- A Send Reminder synchronizes end-to-end encrypted as an additive revisioned record with a cancellation tombstone; its Draft remains the content authority, and only the current reminder revision can be opened, cleared, or rescheduled

- For Scheduled Send, the backend may read only the Product Account, opaque schedule identity, absolute delivery instant, 24-hour deadline, expected encrypted-record revision, scheduled wake identifier, admission state, claim owner, claim generation, claim phase and timestamps, compatible device-authorization generation, and terminal or cleanup state without message outcome details; recipients, subject, body, assets, selected Mailbox Connection, and provider results remain end-to-end encrypted, and provider credentials remain device-local

- Any compatible trusted device with the selected **Mailbox Authorization** and **Scheduled Delivery Authorization** may acquire the one active **Scheduled Send Claim**; provider handoff fences every other device until its result is reconciled

- Opening a Scheduled Send for editing first acquires a synchronized edit fence; editing, rescheduling, cancellation, mode conversion, and delivery claiming compare the same synchronized revision so they cannot create duplicate delivery commitments

## Reader loading

The conversation reader's load coordinator gives bodies intersecting the visible
viewport priority over every off-screen body and immediately reprioritizes when
scrolling changes visibility.
