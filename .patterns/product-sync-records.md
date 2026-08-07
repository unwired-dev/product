# Product Sync Record Patterns

Use the typed Product Sync record boundary for product-owned state synchronized through
[End-to-End Encrypted Product Sync](../CONTEXT.md#language). The privacy and recovery decision
remains [ADR 0001](../docs/adr/0001-end-to-end-encrypted-product-sync.md); use the established
domain vocabulary in [`CONTEXT.md`](../CONTEXT.md) instead of defining record-specific synonyms.

## Choose the record shape

- Use `ProductSyncSingletonDefinition` when one Product Account owns one logical value at a stable
  identifier. Preserve a deployed identifier and payload schema when migrating an existing record.
- Use `ProductSyncRecordFamilyDefinition` when callers already own safe opaque identifiers and need
  listing or exact reads for independently updated records.
- Use `ProductSyncKeyedRecordFamilyDefinition` when the boundary must derive opaque addresses from
  sensitive domain identities. Supply canonical identifier bytes; the boundary owns keyed hashing
  with the current and retained account keys.

Record values must be `Codable` and `Sendable`. A domain service owns payload validation, merge
semantics, tombstones, and which concurrent value wins. It receives typed values and opaque
revisions; it must not receive the payload transport, key-material store, ciphertext, associated
data, or raw account-key bytes.

## Keep cryptography and transport inside the boundary

Create singleton or family handles from `ProductSyncRecordBoundary`. The boundary owns key lookup,
JSON encoding, AES-GCM associated data bound to the exact payload identifier, encryption,
decryption, bounded reads, conditional writes, cancellation-aware retry limits, and lock ordering.
Only Product Account bootstrap, recovery, and rotation code may create or restore Product Sync key
material. Record callers require existing material and must never create a replacement key.

The production `ConvexProductSyncRecordTransport` exposes only paginated listing, bounded exact
reads, and compare-and-set writes. Do not add unconditional or write-if-absent record operations;
conflict behavior belongs to the typed handle and the domain decision closure.

## Select a cache policy explicitly

- `authoritative`: every read comes from Product Sync.
- `authoritativeWithCiphertextFallback`: an authoritative read may fall back only to the permitted
  device-local encrypted snapshot.
- `invalidateBeforeWrite`: clear ciphertext before a write can start.
- `invalidateBeforeWriteAndRefresh`: clear before writing and refresh only from confirmed or
  authoritative ciphertext.
- `invalidateThenRefresh`: invalidate before a domain-controlled update and refresh afterward.
- `refreshAfterCommit`: cache only a confirmed committed record.

Cache adapters store ciphertext, never plaintext. Keep product-specific fallback eligibility in the
domain service, while cache invalidation and refresh ordering stay in the record boundary.

## Test through the owning interface

- Keep focused `ConvexProductSyncRecordTransport` contract tests for paths, authentication, request
  fields, pagination, exact reads, and conditional-write responses.
- Keep in-memory boundary tests for encryption, associated-data binding, key safety, batching,
  pagination, cache ordering, locks, conflicts, retries, and cancellation.
- Inject a configured `ProductSyncRecordBoundary` into domain tests and assert domain outcomes such
  as validation, merge decisions, tombstones, and error mapping. Do not recreate encryption,
  unconditional-write, retry, or cache-ordering tests in every domain suite.

New records should update this pattern only when the shared interface changes. Record-specific
privacy or conflict decisions belong in the applicable existing ADR; create a new ADR only for a
new durable architectural decision.
