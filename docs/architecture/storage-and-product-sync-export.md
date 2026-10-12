# Storage and Private Sync export: architecture notes

Reviewer-only companion to [docs/storage-and-product-sync-export.md](../storage-and-product-sync-export.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Private Sync export

The client paginates every exportable Private Sync record, excluding the Product Account recovery payload, decrypts each payload on device with its record identifier as authenticated associated data, and writes readable, sorted JSON.
