# Privacy and sync: architecture notes

Reviewer-only companion to [docs/domain/privacy-and-sync.md](../../domain/privacy-and-sync.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Authorized Remote Content Cache

Its quota is shared, but every entry is encrypted and namespaced by Product Account, Mail Profile, Mailbox Connection, stable message identity, and resource revision without cross-Profile deduplication.
