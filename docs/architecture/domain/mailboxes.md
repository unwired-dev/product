# Mailboxes: architecture notes

Reviewer-only companion to [docs/domain/mailboxes.md](../../domain/mailboxes.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Stable Provider Connection Key

The Stable Provider Connection Key is derived from the provider type and **Stable Provider Mailbox Identity** (and verified endpoint when needed).
