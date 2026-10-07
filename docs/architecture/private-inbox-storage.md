# Private inbox storage: architecture notes

Reviewer-only companion to [docs/private-inbox-storage.md](../private-inbox-storage.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Ownership and failure behavior

`native/private-inbox` owns a versioned AES-256-GCM encrypted snapshot, using
CryptoKit and Security without a third-party database dependency. This small
fixture store is not a general mail database and is separate from the
[Gmail body cache](#gmail-body-cache). The complete preview fixture, including
metadata and bodies, is encrypted in `inbox.enc`
under the host's Application Support directory. The directory is excluded from
backup; iOS writes also use complete file protection. Atomic ciphertext replacement
and file synchronization finish before an update resolves. Temporary writes
contain ciphertext, not fixture plaintext.

The native Keychain item uses `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`,
`kSecAttrSynchronizable: false`, and the Data Protection Keychain on macOS. Apple documents the [device-local accessibility policy](https://developer.apple.com/documentation/security/ksecattraccessiblewhenunlockedthisdeviceonly)
and [Mac Data Protection Keychain selection](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain). The native module uses
React Native's legacy-module interoperability in both hosts.

On iOS, protected-data availability is checked before filesystem access and again
before first-run seeding.

A native file lock covers each read-modify-write operation, including first
initialization. Each mutation reloads the latest ciphertext and changes only the
requested message. The shared store
serializes operations with an Effect semaphore and publishes updates to all mounted views.

`SyntheticCredential` owns a separate Keychain service and lifecycle. It creates
a random synthetic secret, uses it natively for a fixed local HMAC challenge,
and removes it idempotently.

## Gmail mailbox cache

Issue #604 added a separate encrypted `mailbox.enc` document; #606 gives each
connection its own `mailboxes/<opaque-id>/mailbox.enc` and body directory. It holds the mailbox address, Google subject, revision and TypeScript-owned messages
and synchronization checkpoint. AES-GCM authenticates its separate
`dev.unwired.private-inbox.mailbox.v1` context. It shares the device-only database
key and native file-lock, atomic replacement, synchronization, protection and
backup policy described above. Neither file's ciphertext opens as the other.
An existing file requires its existing key. First mailbox initialization must
also refuse a replacement key when the preview file already exists.

Opening for another address or Google subject exposes no document; a cache without
a subject also exposes no document. Cache operations return no subject field; the
registration snapshot lists opaque connection IDs, addresses and device-local
authorization states; it no longer returns `providerSubject`. A commit compares the persisted
revision under the lock before replacing it. Connection removal removes its directory; an address or subject mismatch still closes access if that cleanup fails.
Registration cache replies include an opaque native generation, checked for every
provider read and commit. A stale synchronization cannot reuse revision zero
after reselection or purge, even when the new mailbox has the same address. Account
purge removes it before keys and keeps the registration locator until all
cleanup succeeds. Removal needs no decryption key. The bounded metadata document
is not an indexed general mail database or the replacement body cache.

The [Gmail companion](gmail-inbox.md) records transport ownership and suspension
fences. Observable cache requirements remain in the operational storage guide.

## Gmail body cache

Issue #605 adds per-message ciphertext under each connection’s `bodies/`, separate from both
metadata documents. Filenames are SHA-256 digests of the Google subject, mailbox
address and Gmail ID; AES-GCM associated data authenticates that exact tuple
under the `dev.unwired.private-inbox.body.v1` context. The existing device-only
database key, file lock, backup exclusion, atomic replacement, synchronization
and complete file protection still apply. Keys never cross the bridge. A failed
body authentication returns absence. When writes are authorized it removes only
that disposable body; cache-only access preserves ciphertext and access times.

The native vault enforces a 500 MB stored-byte budget across all connection body directories
and the unadopted legacy root `bodies/`. The global scan counts that directory
until adoption or removal; lazy adoption moves it under one connection while
holding the same file lock, so it is never counted twice. Global eviction may
remove legacy bodies but preserves their metadata document and pending actions.
Listing and membership pruning still scan only the named connection.
Admission includes the nonce and authentication-tag overhead, plans all eviction
before deleting anything, and refuses an entry that cannot fit. Tier suffixes
separate opened and prefetched files. Eviction considers opened entries first,
then prefetched entries, each least recently read with filename tie-breaking;
the current recent working set is protected. Admission conservatively counts the
old opposite-tier ciphertext together with its replacement; only the exact
atomic-replacement target is discounted. A refused admission preserves the old
body. After admission, the opposite tier is removed before publishing the new
file, so interruption cannot leave two valid tiers for one body. A failed or
interrupted replacement may leave a disposable cache miss, fetched again on demand.
Verified reads update access time; retention/pruning reconciles an over-budget
directory left by an older interrupted writer. Metadata is never evicted.
Pruning also compares the expected metadata revision under the same file lock
before any body deletion, rejecting a competing store's stale list with conflict.
Registration wrappers validate the opened mailbox generation; offline cache-only
access is read-only, including for corrupt files, and refuses writes or pruning.
Listing returns IDs without decrypting stored bodies. Mailbox removal and account
purge remove bodies with the metadata cache.

Purge and Gmail reselection await detached, file-locked removal of both the metadata
cache and the body directory under the bridge's registration gate. Deletion and lock
waits leave the main actor available; the gate remains held until removal completes.
Purge invalidates the generation and session state and records acknowledged removal
before suspending. It still attempts account-key cleanup after cache-removal failure
and keeps the registration locator for retry until every cleanup succeeds. Removal
requires neither a decryption key nor unlocked protected data, so forgetting remains
possible on a locked device. Reselection retains its best-effort removal behavior;
mailbox-owner and generation checks prevent access to an old cache after failure.

RegistrationStore body operations check protected-data availability and the mailbox owner
and generation on the main actor, perform locked file and CryptoKit work in a detached
task, then repeat those checks before publishing success. Errors are also reclassified
as locked when protected data became unavailable. The bridge's FIFO registration gate
remains held across the awaited work, including revocation preflight and purge paths.
The fixture bridge retains its serial worker queue and checks availability on the main
actor before dispatch and before resolving or rejecting the worker result. The production
iOS availability callback reads UIKit only on the main thread; off-main store checks
rely on these adapters' surrounding checks and on Keychain/file protection, avoiding a
synchronous hop to the main actor while holding the file lock.

This adds platform storage operations permitted by
[ADR 0067](../adr/0067-keep-native-code-to-a-minimal-vault.md); MIME decoding,
presentation preparation and application sequencing remain in TypeScript.

## Legacy cache ownership and cleanup

The earlier root `mailbox.enc` and `bodies/` are lazily adopted only after their
saved subject and address match a connection. Adoption
preserves any body already saved in the connection directory when merging the
root `bodies/`, comparing message identity across opened and prefetched tiers.
The merge runs under the file lock and leaves root metadata until body migration
finishes, so an interrupted merge resumes without replacing destination bodies.
Converting an earlier registration
preserves its opaque ID in `legacyMailboxConnection`; cleanup consults this marker
(or the still-legacy registration) before dispatching detached keyless removal.
Removing that connection deletes its root artifacts even before its first cache
open. Removing another connection preserves the root metadata and its durable
pending actions. Account purge removes every layout. Cache deletion attempts all
owned paths and retains the first failure, so failure on one path does not skip
other known private data. Completed per-connection cleanup clears its retry marker.
