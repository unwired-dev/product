# Organization: architecture notes

Reviewer-only companion to [docs/product/organization.md](../../product/organization.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

These terms include prototype organization features and follow-up work.
References to a feature's first release or v1 retain their original scope; they
do not add that feature to the focused replacement release.

## Decisions and scope

- [Accepted replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Allow multiple Categories per message](../../adr/0024-allow-multiple-categories-per-message.md)
- [Make Inbox Cleanup reviewed and recoverable](../../adr/0043-make-inbox-cleanup-reviewed-and-recoverable.md)
- [Synchronize Muted Threads as product state](../../adr/0051-synchronize-muted-threads-as-product-state.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Pins

- Legacy message Pins migrate idempotently to their containing **Thread**, deduplicate by **Stable Thread Identity**, and remain until the corresponding Thread **Pin** is durably synchronized; a message without reliable linkage forms a one-message Thread

## Mute and blocked senders

- New replies do not clear a **Muted Thread**, and rethreading repairs its identity through the stable anchor message without changing provider mail

## Category membership

- Legacy single-category assignments migrate idempotently to one-member Category sets while preserving assignment source, override state, and learning signals; mixed-version synchronization remains readable and cannot collapse a multi-category set to one value

## Categorization and conflicts

- The multi-Custom-Category collection activates only after a synchronized minimum-client generation fences legacy singleton clients; updated devices dual-write and merge the legacy definition until every trusted device acknowledges that generation or is revoked, then retire the singleton record

- Deleting a Custom Category writes a synchronized tombstone, removes it from active Mail Views and notification eligibility, and preserves historical message memberships and learning records as inactive references until every trusted device has observed the tombstone; an offline edit conflicts with the tombstone rather than recreating the Category silently
