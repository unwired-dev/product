# Mailboxes: architecture notes

Reviewer-only companion to [docs/product/mailboxes.md](../../product/mailboxes.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

The replacement launches with Gmail. The engine dependency, certified
Standards-Based Mail and legacy-provider terms describe the Swift prototype or
future work; they do not establish support in the new client.

## Decisions and scope

- [Accepted replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Keep mailbox authorization device-local](../../adr/0010-device-local-mailbox-authorization.md)
- [Preserve provider-native mail adapters](../../adr/0011-provider-native-mail-adapters.md)
- [Require trustworthy mailbox role mapping](../../adr/0014-explicit-mailbox-role-mapping.md)
- [Queue provider mail actions optimistically](../../adr/0015-optimistic-durable-provider-actions.md)
- [Require secure mail transport](../../adr/0017-require-secure-mail-transport.md)
- [Use a qualified third-party mail protocol engine](../../adr/0027-qualified-third-party-mail-protocol-engine.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.

## Connection identity and authorization

- After wake or reconnect, a trusted device processes synchronized connection-removal tombstones before it resumes any queued **Provider Mail Action** or **Outgoing Delivery Attempt** for that connection

- Re-adding an existing provider mailbox authorizes or repairs its **Mailbox Connection** instead of creating a duplicate; after synchronization, trusted devices group equal **Stable Provider Connection Keys** under a durable encrypted merge record, choose the lexicographically lowest connection identifier as its winner, and atomically fence every loser at that record's merge epoch before an idempotent transfer of product-owned pins, categories, pending actions, and Outbox attempts. The winner records completed transfers by loser and merge epoch before a durable loser tombstone prevents resurrection; concurrent writes must retry against the winner and current epoch. Before a device deletes a losing record, it re-keys its local authorization and cached mail to the winner or requires authorization there, so no local credential or queued work is silently lost.

- Recreating a removed **Mailbox Connection** with the same **Stable Provider Mailbox Identity** advances a synchronized authorization generation; every device-local **Mailbox Authorization** is bound to one generation, so an offline credential from before removal requires reauthorization after reconciliation

## Provider capabilities and engine boundary

- The **Approved Mail Engine Dependency** owns IMAP and SMTP transport, authentication, framing, parsing, MIME, IDLE, UID operations, and submission; product code owns durable state, role and capability policy, Stable Provider Message Identity, retry, and reconciliation. There is no product-owned IMAP or SMTP wire-protocol fallback; the legacy stream implementation remains only for POP3

- A verified `COPYUID` continuation is persisted before UIDPLUS source deletion; recovery reuses that mapping rather than copying again, targets only the recorded source UIDs, and transfers local product state to the destination identity

## Pending provider actions

- Each **Pending Provider Action** has a stable idempotency key and immutable attempt record; an ambiguous provider response is reconciled before retrying so the provider mutation is not duplicated

## Bulk actions and provider rollout

- Each bulk batch expands into ordered actions behind existing pending actions for its **Mailbox Connection**; execution is serialized per connection, while cross-connection batches may proceed independently and preserve successful batches when another connection fails
