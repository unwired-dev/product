# Private product sync: architecture notes

Reviewer-only companion to [docs/private-product-sync.md](../private-product-sync.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Keys and envelopes

Each Product Account has a
device-only Keychain item (`WhenUnlockedThisDeviceOnly`, not synchronizable, Data
Protection Keychain on Mac). It holds the account key ring and publication state. The initializing device
also holds the Recovery Key, recovery envelope and confirmation state; an enrolled
or recovering device receives only the key ring.

- **Key ring.** A random 256-bit AES key per epoch, starting at epoch 1. Earlier
  epochs stay in the ring for older records, matching
  [ADR 0020](../adr/0020-revoke-devices-with-sync-key-rotation.md) rotation.
- **Records.** AES-GCM-256 with a fresh random 96-bit nonce for every seal.
  The authenticated data binds the Product Account ID, the opaque record
  identifier, the algorithm, the key epoch and the record schema. Convex stores
  only the algorithm, nonce, ciphertext, tag, key epoch and schema, plus its own row metadata
  such as `updatedAt` for compare-and-set. Changing any sealed field, moving a record
  to another identifier or account, or relabelling its epoch fails authentication;
  row metadata is not authenticated. Records with an unexpected schema are rejected.
- **Record identifiers.** `mailbox.` followed by a truncated HMAC-SHA-256 of the
  provider subject. The HMAC key is derived from the first epoch key. Identifiers
  are stable across devices and epochs. They reveal no address or subject, and
  they differ between Product Accounts.
- **Recovery envelope.** The key ring encrypted with a key derived by HKDF from the
  Recovery Key and the Product Account ID. Its authenticated data also binds the
  account, epoch and schema. Schema 3 marks this format; the prototype's unbound
  schema 1 and 2 wrappers are never opened. It is stored under the reserved
  `product-account-recovery-v1` identifier.
- **Enrollment envelope.** HPKE (X25519, HKDF-SHA-256, ChaCha20-Poly1305) seals
  the key ring to one enrolling device's public key. PSK-mode HPKE info and authenticated data bind the Product Account, target
  Pending Device and key epoch. Its current one-time public key identifies the request; renewing it invalidates earlier approvals. The Enrollment Code supplies the PSK.
  [Trusted-device enrollment](#trusted-device-enrollment) defines transport and storage.

Mailbox descriptor reconciliation treats every record it cannot open or decode
as read-only, including authentication failures at the current schema and a
known epoch. A newer client may use bindings an older client cannot authenticate
even at the same schema and epoch; replacing that record could discard a removal
fence. Preserving it follows the tombstone and downgrade protections in
[ADR 0001](../adr/0001-end-to-end-encrypted-product-sync.md) and
[ADR 0010](../adr/0010-device-local-mailbox-authorization.md). The backend can
already remove ciphertext, so overwriting an authentication failure adds no
recovery guarantee against backend tampering. The observable write policy remains
in [the operational guide](../private-product-sync.md#keys-and-envelopes).

## Initialization and relaunch

`productAccount:connect` reports whether the Product Account already has Product
Sync material.

Native
clients read records through every 100-record page.

`productSync:initialize` stores the first recovery envelope and its purpose-specific Recovery Key verifier and marks the account
initialized in one mutation. It requires the authenticated Trusted Device proof
and the current key epoch. It returns `initialized: false` when the account
already has other material or any encrypted record, so exactly one device wins. Repeating the winning
envelope after a lost response succeeds without another write. A device that
loses discards its unpublished keys, which have protected nothing, and needs
enrollment. No record is written before publication succeeds. The legacy
recovery-material replacement route still requires recent authentication.

Convex checks for the account's recovery envelope before single-record inserts
or updates and before atomic record checks, deletes or writes. The legacy
`markProductSyncMaterialInitialized` mutation likewise requires the envelope.
Both `productSync:initialize` and first publication through the legacy
recovery-material route use the same helper to insert the envelope and set
`productSyncMaterialInitializedAt` in one mutation. An existing marker or record
without an envelope prevents both paths from creating new key material; the
legacy route returns HTTP `409`. This preserves earlier encrypted data instead
of silently resetting its keys. An envelope left without a marker by the earlier
legacy route can still acquire the marker through the guarded marker mutation
or an exact-envelope retry of `initialize`, without replacing that envelope.

The vault
keeps the mailbox list it last decrypted, so the list stays visible, and records
which descriptors this device read back.

## Trusted-device enrollment

[#750](https://github.com/unwired-dev/product/issues/750) implements
[ADR 0066](../adr/0066-admit-devices-only-through-authorized-enrollment.md).
Product Sign-In admits only the first key-creating device. Every later installation
starts in `pendingDevices`, separate from the Trusted Device table and invisible
to ordinary account operations, encrypted-data reads, push routing and rotation counts.
An account with no initialized keys and no Trusted Device may assign its next
installation to create the first keys; it cannot replace existing material.

The Pending Device authenticates its own request with Product Sign-In and a
device-only credential whose digest Convex stores. It may request or renew
approval, read its status, receive a sealed ring, submit Recovery Key proof,
confirm durable key adoption, sign out, or delete the account after recent
interactive sign-in. All other entry points require Trusted Device proof.
Product-Sign-In-only legacy Product Sync reads are removed. There are no existing
users to migrate, and the legacy Swift host is not adapted.

The requesting device creates a one-time X25519 key and an Enrollment Code with
55 uniformly random Crockford digits, providing 275 bits of entropy, plus one
SHA-256-derived check digit. HKDF-SHA-256 derives a 32-byte PSK from the normalized
code. [RFC 9180 section 9.5](https://www.rfc-editor.org/rfc/rfc9180.html#section-9.5)
requires at least 256 bits of PSK entropy; expanding a shorter code with HKDF
would not satisfy that requirement. The check digit catches most typing mistakes
and adds no entropy. A shorter human code needs a separately designed and
qualified protocol, rather than weakening this PSK.

The trusted person transfers the code directly from the requesting device to
the key-holding device. The backend never receives it. The approver seals its
existing key ring with CryptoKit's Curve25519/SHA-256/ChaChaPoly HPKE PSK mode.
Length-prefixed info and associated data bind account, Pending Device and key
epoch. The current one-time public key and code fence renewal of the request. A backend public-key substitution yields ciphertext it cannot open
without the code, and a forged approval without the code cannot be opened by the
requester. Native decoding also validates the envelope's declared key epoch and
key lengths. This flow uses normal authenticated device access and explicit
code entry; it does not replace or disclose the Recovery Key. The accepted ADRs
require recent authentication for recovery-material replacement and other named
sensitive operations, but do not impose a separate authentication-age limit on
this approval path.

The one-time private key and code live in a device-only Keychain item bound to
account and Pending Device. The new device saves the adopted ring before
confirming admission or removing that item. This approval path gives it no Recovery
Key or recovery envelope, and cannot initialize or replace the account's existing
material.

The Pending Device and its code have a 15-minute window; approval grants a fresh
15-minute collection window. Each identifier has one pending record, with at most
three unexpired records per account. Expired records are cleaned up in bounded
batches. Pending Devices do not count toward the Trusted Device limit, which the
admission transaction enforces. `listPending` and `status` are mutations used as
explicit refresh operations, so each evaluates fresh server time.

Approval requires a live Trusted Device of the same account acknowledged at the
newest epoch. The native approver adopts a pending rotation first. Approval also
names the public key it sealed to, so a concurrent request renewal cannot collect
that ring. Status and confirmation revalidate approver membership and the newest
epoch. Confirmation names the epoch actually stored in the vault; an older saved
ring cannot acknowledge a newer approval. Only a valid confirmation creates the
Trusted Device acknowledged at that epoch and deletes the pending record and
envelope. No rotation transition is returned during admission.

Removal through a retained Trusted Device ID also deletes any Pending Device
with that installation's identifier in the same Product Account. An installation
that signed out and returned to wait cannot survive its removal as a pending
record. `productSyncEnrollment.complete` independently rechecks the account-scoped
identifier tombstone before creating a Trusted Device; a pending record that
outlived removal is deleted and receives `admitted: false`, even with a current
approval or Recovery Key authorization.

An unreadable ring, removed approver or superseded epoch leaves the device pending;
the client discards unusable saved keys and asks again with a fresh key and code.
Credential reissue after a lost connection reply likewise clears old authorization.
Sign-out removes the pending record; when confirmation already committed but its
reply was lost, the same credential unregisters that admitted installation instead.
The two mutations arbitrate in one transaction order, preserving rotation completion.
Account deletion drains all pending records in bounded batches. Expired approvals
are withheld until cleanup, renewal, sign-out or deletion removes them.

Refresh is explicit on both devices; pending requests on the approver are kept
only in memory. Google can renew silently, while Apple requires interactive
sign-in after relaunch. Mock journeys use isolated synthetic identities and
controlled transport. Real Keychain and CryptoKit evidence establishes local
encryption boundaries, not deployment JWT verification or two real devices.

## Recovery Key adoption

[#601](https://github.com/unwired-dev/product/issues/601) adds explicit Recovery Key
entry beside approval. Under ADR 0066, a Pending Device must prove the Recovery
Key before receiving its recovery envelope. HKDF-SHA-256 derives an account-bound
value under purpose `recovery-verifier`, distinct from the `recovery-key` encryption
key. The device sends only that value; Convex compares its SHA-256 hex digest with
the verifier published atomically with initialization, Recovery Key replacement
or revocation. The verifier cannot open the envelope. A malformed key is rejected before renewing
Product Sign-In. Before reading the recovery envelope for a well-formed key, Google
renews its Product Sign-In silently and Apple signs in interactively on every
attempt. The existing subject and Product Account checks fence the renewed
identity, including after relaunch. Reusing an in-process Apple token would strand
retries after expiry and violate [ADR 0001](../adr/0001-end-to-end-encrypted-product-sync.md)'s
recovery authentication requirement.

Already-trusted devices may read the committed reserved recovery envelope with
their authenticated device proof. A Pending Device receives only the envelope
its proof authorized: the pending replacement envelope during rotation, otherwise
the committed envelope. During a pending rotation the previous Recovery Key
admits no new device, but remains usable by already-trusted devices until commit.
On commit the replacement verifier moves with its envelope to committed state.

Native CryptoKit opens schema 3 using the entered Recovery Key and the
Product Account binding. Adoption also requires the declared current epoch to
match the ring, its key to exist, and every key to have 32 bytes. Only then does
the device save a published, confirmed vault with the account's existing ring. A Pending Device confirms the stored epoch before becoming trusted.
It neither stores the Recovery Key nor initializes or replaces recovery material.
It reads the encrypted mailbox descriptors; Gmail credentials remain device-local
and require their own authorization.

Reconnect may create or refresh an enrollment request before the key is checked.
If the key cannot open the envelope, native recovery resolves with the current
registration status plus a transient `recoveryNotice: "rejected"`. The shared store
consumes the notice and publishes that snapshot with `recoveryFailure: "rejected"`,
so an expired or cancelled request's replacement Enrollment Code remains visible.
Malformed keys use the same status-and-notice reply without reconnecting. The
notice is not persisted or returned on restore; rejection does not use a native
promise error code.
Recovery saves verified keys before confirmation. A crash before that save leaves
recovery retryable without keys; a crash after it retains the ring for confirmation.
A lost confirmation reply is reconciled by reconnecting with the same credential,
which returns the admitted Trusted Device receipt. A stale epoch is refused and
discarded before renewed approval or proof. The Recovery Key itself is not stored
by the recovering device. A wrong proof returns nothing and preserves the current
Enrollment Code. These operations do not reset encrypted data or touch provider mail.

Losing all Trusted Devices while holding only the previous Recovery Key during a
pending rotation leaves deletion as the only remaining path. A remaining device
that never reconnects can keep that rotation pending. This is the accepted recovery
limit, not an implicit reset or authorization bypass. Losing every key-holding
device and the Recovery Key leaves encrypted product data unrecoverable; this
interface offers no reset.

The [qualification record](../qualification/expo-react-native-client.md#recovery-key-evidence-2026-10-04)
records the 2026-10-04 iOS storage and packaged recovery/enrollment passes after
the initial reviewer corrections, plus a fresh iOS storage pass for the rejection
snapshot fix. The packaged journeys were not rerun for that follow-up. Real
Keychain and CryptoKit checks use a synthetic Convex
boundary; packaged journeys use Mock Mail Sessions. That run left Mac recovery
automation and hosted storage pending. The [operational guide](../private-product-sync.md)
records #750's later mocked Mac, iPhone and iPad journeys and final hosted iOS
regressions. Mac hosted storage, physical devices and protected Convex and
provider qualification remain deferred.

## Device revocation

Issue [#602](https://github.com/unwired-dev/product/issues/602) connects the
replacement hosts to the existing recent-authenticated revocation route for
Google and Apple. Native code adopts a pending epoch before proposing a fresh
one, retains every prior epoch, and seals the rotation ring with the committed
epoch's key using account-bound purpose `rotation`, schema 1. Backend device
proof and tombstones withhold that transition from the removed device even though
it held the committed key. Key possession alone never authorizes its retrieval.

This is an authorization fence, not cryptographic exclusion from stored
transitions. The removed device's committed epoch key plus read access to Convex
storage can open the pending transition and obtain the new ring. Per-device
sealing to secrets the removed device never held requires a protocol change and
is tracked in [#753](https://github.com/unwired-dev/product/issues/753), blocked
by #602. This slice does not establish that stronger guarantee.

Each applied removal creates a new Recovery Key and schema 3 recovery envelope,
so the previous Recovery Key cannot open the replacement recovery envelope.
Revocation is idempotent by installation within the Product Account, including
retained row IDs from before sign-out and reconnect. After authenticating the
caller and resolving the account-owned live or retained target,
`productAccount.revokeTrustedDevice` compares the authenticated live device's
`deviceIdentifier` with the target's identifier and refuses self-removal with the
existing sign-out error, including through an earlier retained row ID. This guard
precedes the installation tombstone check and either rotation path, so an alias
cannot remove the caller's current row or strand rotation without a surviving
device. The mutation then checks the installation's `deviceIdentifier` tombstone.
A previously removed installation returns
the current pending or committed rotation status without replacing the transition
or recovery envelope and without adding another tombstone. The exact-ID retry
check remains available even when no retained target exists.
Before sending, the native vault durably preserves the generated Recovery Key,
exact transition and requested target ID.
A lost connection, cancellation or ambiguous server response keeps this marker;
a known refusal clears it. Synchronization promotes the preserved Recovery Key
only when the authoritative pending transition matches. A successful idempotent
revocation reply alone proves no adoption: the target may already be revoked
without applying this request. The host emits `revocationNotice: "removed"`
only when the stored Recovery Key matches this removal's generated key after
synchronization; otherwise it emits `unconfirmed` and preserves the confirmed
key. A failed transition read retains the pending marker for the next
synchronization; an authoritative mismatch clears it without promoting the
unapplied key. It durably saves the adopted ring before acknowledging. A retried
`revoke` that adopts its unanswered attempt returns the `recovery-key` snapshot
instead of throwing on the unconfirmed-key guard; it emits `removed` only when
the saved target ID matches the requested target. A different target, or an older
marker without a target ID, still surfaces the adopted key but claims no removal
for that request. An already shown, unconfirmed key likewise returns its status
without a notice. Neither path sends another removal or replaces the key before
confirmation. Surviving devices open the transition with a held
key and require it to retain every held key. The backend publishes the new
recovery envelope only after every remaining device acknowledges; until then
backup guidance retains the previous key as well as the new one.

Every registration bridge operation enters `RegistrationStore.purgingIfRevoked`.
When a readable saved registration contains a Product Account, this boundary calls
`requireNotRevoked` using `productAccount:isTrustedDeviceRevoked` before invoking
the requested operation. Restore, Linked Sign-In, signing in again, provider
switching, Recovery Key unlock and removal therefore check before provider
validation or an interactive prompt. Failed provider renewal or prompt
cancellation cannot suppress credential-proven revocation. An unreadable
registration skips the preflight and leaves the operation to report its own
failure; this preserves purge's clearing of in-memory authorization before its
throwing registration read. Transport unavailability likewise leaves the
requested operation's resumable/offline and cancellation behavior intact.
The query authenticates only the device's revocation rejection, using the
account-scoped tombstone and SHA-256 digest of the credential copied at removal;
it returns one boolean and grants no account data or API access. It needs no
renewable Product Sign-In token, which Apple relaunch cannot supply. Invalid IDs
or a mismatched credential disclose nothing. Transport unavailability retains
local state. A positive rejection removes the account vault, enrollment item and
registration record (including identity and mailbox credentials) before later
provider work. The unrelated encrypted synthetic Inbox fixture has no account
ownership and is outside this purge; the Gmail mailbox cache joins this boundary in #604. Future account-owned mail
storage must join it too. Purge clears in-memory authorization before reading the persisted
registration, attempts every known account item despite a deletion failure and
throws the first failure before deleting registration. Registration is removed
last, preserving the account locator for a later cleanup retry. Unregistration
retains only the credential digest in the existing minimal revocation-target
record, so owner removal after sign-out still supplies this
rejection to the old installation. Removal also retains the digest of any live row with that installation
identifier. A reconnect between target selection and revocation can change its
row ID; the credential-only query then matches that retained proof and the
installation tombstone. The target digest is not a live authorization grant,
and account deletion already drains these target records.

### Authorized enrollment after removal

ADR 0066 supersedes ADR 0020's account-wide unseen-identifier lock and its
identifier-history migration. Issue #750 removes the lock, migration gate,
migration mutation and registration history. The removed installation identifier
and credential stay refused; an invented identifier gains only Pending Device
access. Hosts show the enrollment gate and permit Gmail authorization only after
admission. The previous key's continued use applies to already-trusted devices.

The retained flow still uses the existing native coordinator. ADR 0067 stages its
move to TypeScript through #756–759; native key custody, credentialed transport
and persist-before-acknowledge guarantees remain in force during that migration.
This slice does not claim those later flow migrations or live-provider qualification.
