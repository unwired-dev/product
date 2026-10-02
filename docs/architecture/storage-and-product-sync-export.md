# Storage and product sync export: architecture notes

Reviewer-only companion to [docs/storage-and-product-sync-export.md](../storage-and-product-sync-export.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Product Sync export

The client paginates every exportable encrypted Product Sync record, excluding the Product Account recovery payload, decrypts each payload on device with its record identifier as authenticated associated data, and writes readable, sorted JSON.
