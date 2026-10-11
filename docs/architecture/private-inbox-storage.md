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

## Default Profile foundation

Issue #644 adds `profile` to the decoded `MailboxConnection` in
`packages/mail-core/src/registration.ts`. `Schema.withDecodingDefaultKey` accepts
the old JSON form and supplies the account-local `defaultProfile` sentinel;
explicit nonempty ownership is retained and malformed ownership is rejected.
The registration snapshot keeps the original JSON text. Decoding writes neither
native storage nor Product Sync, and credentials and encryption keys remain
native. The mock registration session deliberately emits the same old-form
projection as native code.

The Default Profile retains the Product Account's existing record namespace.
Connections, Drafts, assets, Outbox attempts, caches and encrypted records retain
their identities and locations. The staging decision and its panel outcome are
recorded in [ADR 0048's replacement amendment](../adr/0048-separate-encrypted-mail-profile-ownership.md#replacement-staging-amendment--2026-10-11).
The [caller inventory and release evidence requirements](../private-inbox-storage.md#mail-profiles)
remain implementer-readable. Multiple-Profile creation stays unavailable through
#645 and #646; #647 owns synchronized assignments and incompatible-client fencing.

## Drafts, delivery and notifications staging

Issue #646 scopes shared TypeScript services to the decoded connection Profile:
`sendingMailboxes` requires an explicit Profile; Draft creation validates the
current sender; sender changes and received-attachment imports stay within the
stored Draft's connection Profile; attachment-to-Draft navigation selects only
the reader's Profile; and Reply All excludes only that Profile's own identities.
Both hosts consume these shared boundaries for New Message, From choices and
reader actions. Tests use a synthetic second Profile; production still projects
every connection into the Default Profile.

Draft records and windows do not persist a Profile. `profileOf` therefore resolves
the current connection assignment and falls back to `defaultProfile` for an
unlisted connection or unified Inbox. This is a staged Default Profile boundary,
not proof of isolation during synchronized connection transfer or multi-Profile
window restoration. Those ownership and lifetime fences belong to #647 before
another Profile can be created.

Existing encrypted Drafts/assets, Product Sync identifiers, exact Outbox payloads,
originating Delivery Owners, pending claims and account cleanup retain their
current representation and lifecycle. Convex `draftDelivery.ts`, `scheduledSend.ts`,
`pushRelay.ts` and `apns.ts`, and native `PushRoutes.swift` and `DraftSync.swift`,
continue using the Product Account namespace, which is the Default Profile's
Profile Record Scope. Push wakes remain content-free and synchronization remains
account-wide, including inactive Profiles once they exist. Recipient suggestions
and user-visible notifications are not implemented in the replacement yet.

The implementation decision panel (`claude-fable-5-1`, `gpt-6.1-sol`,
`gpt-6-astra`) chose this TypeScript-only batch over threading an always-default
Profile argument through backend and native APIs, 3–0. Without persisted ownership,
that argument would add migration surface without proving routing isolation;
it would also overlap the native registration migration in PR #866. This follows
#644's staged projection decision. #647 must synchronize assignments and route
the explicitly retained backend/native caller inventory by Profile Record Scope.
The operational [Mail Profiles checklist](../private-inbox-storage.md#mail-profiles)
retains that prerequisite and the required real-provider/native release evidence.

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

## Local Draft storage

Issue #611 adds TypeScript-owned semantic Drafts in `drafts.enc`, sealed with the
existing database key and purpose-specific authenticated context
`dev.unwired.private-inbox.drafts.v1`. The native envelope binds owner and revision.
Opening another Product Account returns no document; commits require the opened
revision under the file lock. The file uses the existing atomic replacement,
synchronization, protection and backup-exclusion policy. An absent key cannot be
replaced while any supported encrypted layout remains. Account purge removes
Drafts with the mailbox caches before deleting the key.

The registration operation gate remains held while detached Draft storage work
runs. Protected-data availability and the Product Account are checked before work
and before returning success; native results crossing the actor boundary are
Sendable values. Draft operations add no Gmail or backend calls.

The shared store tracks its durable base for a bounded three-way CAS rebase.
Independent edits and newly created Drafts survive, and concurrent versions of
one Draft become visible conflict copies. Each editor supplies its prior content
so simultaneous Mac windows cannot silently overwrite completed edits inside the
shared store. Discard publishes removal only after durable storage completion.
An update equal to its editor's immediate prior content leaves the list alone,
while still flushing earlier dirty work. Equality includes identity, conflict
metadata and unfinished recipients and ignores only `updatedAt`.
Closing an empty composer checks current content under that same serialized
operation, so a stale empty editor cannot delete another window's completed work.
Separately, `composer-navigation.create` abandons an empty New Message when a
later destination won and its row was not selected. `createDrafts.abandon`
checks current content and removes it through `change` before saving; failed
saving retains the dirty deletion for the next edit or retry. CAS recovery keeps
another writer's authored version, and `known` permits a same-account nonempty
late edit to survive as a conflict copy with editor rebinding. This cleanup does
not give explicit Discard the same early-removal semantics.

### Local Draft Assets

Issue #612 stores each asset separately under `draft-assets/<id>`, using the
database key with authenticated Product Account and asset identifier context.
SHA-256 verifies the imported bytes. The Draft document contains asset metadata,
state and inline references, never asset bytes or source mailbox authorization.
Received assets use the existing attachment retrieval boundary's connection and
generation checks, then become independent Draft-owned bytes.

The native file lock serializes admission, document replacement and asset cleanup.
Import writes verified ciphertext before a complete reference can be committed.
Each document commit carries a keep list; cleanup runs only after durable document
replacement. A process-wide imported-asset set protects imports not yet named by
a committed reference, including saves by another store instance. Relaunch drops
that protection so the next save can remove orphaned imports. Synced asset downloads
are not pending imports: the already-stored document's keep list protects them, and
its next replacement can reclaim them without relaunch. The combined
Outgoing Content Store admission limit remains 100 MB; an individual import is
limited to 25 MiB without evicting authored content.

The shared store retains completed assets referenced by a live Draft or its
current-session editor histories. Import settlement first patches those histories
and registers their completed references, so deleting an importing image and
undoing after settlement cannot restore a dangling complete reference. Rebinding
an editor to a conflict copy transfers its held assets. Deletion initially keeps
all pre-deletion assets through the durable deletion; after pending edits are
reconciled into any conflict copy, the next commit releases only unused assets.
Account generation and composer lifetime fences reject stale picker results;
native cleanup accepts only picker-owned UUID directories under its exact root.

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
separate opened, prefetched and prefetch-excluded files. #608 adds the excluded
tier so listing can distinguish markers from saved bodies without decrypting them;
older markers remain in the prefetched tier until an explicit open downloads and
caches a body in their place.
Eviction considers opened entries first, then prefetched and excluded entries,
each least recently read with filename tie-breaking;
the current recent working set is protected. Admission conservatively counts the
old other-tier ciphertexts together with their replacement; only the exact
atomic-replacement target is discounted. A refused admission preserves the old
body. After admission, every other tier is removed before publishing the new
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

## Authorized Remote Content Cache

Issue #763 adds disposable remote image ciphertext under each connection's
`remote/`, separate from body and metadata caches. A collision-free encoded
identity binds Product Account, connection, provider subject, mailbox address,
message ID and source URL into both the digest filename and AES-GCM associated
data. Gmail message content is immutable: the normalized request reference within that
stable message identifies the resource revision. The Default Profile foundation
leaves this cache layout intact. Optional Profiles are launch work under
[ADR 0069](../adr/0069-expand-the-apple-launch-to-power-user-mail.md); their
remaining migration must add Profile isolation without reusing another Profile's
entries.

The native file-locked vault counts all connection remote directories toward a
separate 250 MB stored-byte limit. It plans LRU eviction before deleting files
and refuses admission when protected displayed resources cannot leave enough
space. It advances recency through `touchRemoteContent` only after TypeScript
admits cached bytes to an actual reader presentation; opening alone leaves recency
unchanged. Fetched bytes are committed only after that same presentation admission.
The shared account ledger sends connection/message/URL triples; native
registration resolves each connection's saved subject/address before constructing
its protected filename. Thus eviction for one connection cannot evict another
connection's displayed content. Existing-key lookup happens before disposable
authentication failure handling, preserving ciphertext on Keychain failure.
Connection removal and account purge remove these directories before keys, and
Clear Remote Content removes only remote entries.

## Legacy cache ownership and cleanup

The earlier root `mailbox.enc` and `bodies/` are lazily adopted only after their
saved subject and address match a connection. Adoption
preserves any body already saved in the connection directory when merging the
root `bodies/`, comparing message identity across every supported tier.
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

## Saved registration vault

The saved registration is one device-only Keychain record per host and Google client.
It holds the Product Sign-In's renewal credential, this installation's identifier,
the Product Account receipt with its Trusted or Pending Device credential, each
Mailbox Connection's Gmail credential and receipt, and any removal waiting for its
answer. Product Sync keys and an open enrollment request are separate Keychain items
of the same account.

The [registration flow](../google-registration.md#where-the-registration-flow-runs)
runs in TypeScript, which never reads this record. It reads a projection without
device credentials, Product Sign-In or provider tokens, the installation identifier
or provider subjects. The `call` operation returns Convex reply bodies to TypeScript,
including the one-time sign-in link ticket it presents to `/sign-in-links/complete`;
native code attaches the requested credentials without returning them. TypeScript changes
the record only through native operations named by purpose: saving the latest
sign-in, connecting, adding, confirming or marking a connection, recording why
setup ended, recording or withdrawing removal intent, and purging. Native code saves
a sign-in before any backend request, so an interruption keeps it; it never replaces
a record that already received a Product Account, and it ignores a record for
another deployment or client. Purging removes every connection's cache, then the
Product Sync and enrollment items, and the registration record last, so a failed
purge is retried.
