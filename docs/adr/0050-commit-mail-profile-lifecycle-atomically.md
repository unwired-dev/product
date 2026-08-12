# Commit Mail Profile lifecycle changes atomically

## Status

Accepted.

## Context

Creating, duplicating, transferring, and deleting Mail Profiles can change the encrypted Profile ownership record together with several Profile-scoped Product Sync records. Committing those writes independently could expose partial ownership, duplicate a connection, or leave reviewed configuration in the wrong Profile after a conflict or cancellation. The backend cannot inspect this state because the payloads are end-to-end encrypted.

Profile duplication must also avoid copying connection-bound or operational state. A transfer must retain the Mailbox Connection's stable identity and device-local authorization while system Categories keep their destination semantics and only reviewed custom Categories are copied.

## Decision

Add an authenticated opaque Product Sync compare-and-swap mutation that validates every read, write, and delete revision before applying a batch in one Convex transaction. The backend enforces authentication, Product Sync key epoch, identifier uniqueness, and a bounded batch size, but does not interpret encrypted Profile content.

Implement Profile lifecycle operations at the Mail Profile service boundary:

- Creating a Profile first records an empty Profile draft in device-local protected storage. Its opaque identity, default quiet state, name, and appearance remain editable while offline; retry later publishes that same identity through encrypted Product Sync.
- Duplicating a Profile accepts an explicit review containing the source revision and configuration kinds. It copies only allowlisted Profile-scoped Categories, Mail Views, workflow preferences, rules, signatures, and templates. It does not copy connections, authorizations, mail, Drafts, Outbox attempts, history, or transient pins.
- Transferring a connection keeps its identifier and authorization generation, atomically changes its Profile assignment, and copies only explicitly reviewed custom Category definitions. Destination system Categories are selected by their existing semantic identifiers; source Profile-wide preferences remain unchanged.
- Deleting a Profile requires a current review proving that it is not the final Profile, owns no connections, and has no unresolved Drafts, Outbox attempts, or pending actions. Its scoped encrypted records and Profile definition are then removed together.

Every lifecycle review carries the authoritative Profile-record revision. Conflicts return current opaque records so the client can refresh and retry; cancellation or any failed precondition commits nothing. Deterministic duplication identifiers make retries idempotent.

## Consequences

- The encrypted ownership record and its dependent encrypted configuration cannot diverge during lifecycle changes.
- The backend gains a general bounded atomic primitive without learning Profile names, ownership, or configuration.
- Profile lifecycle remains a reviewed domain operation; Settings presentation and user flows remain separate work.
- Offline Profile drafts survive relaunch and retain pending edits until an authoritative encrypted write succeeds.
- Large reviewed copies must be narrowed if they exceed the transaction limit.
