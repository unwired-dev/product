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
  device, enrollment request and key epoch. The Enrollment Code supplies the PSK.
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

`productSync:initialize` stores the first recovery envelope and marks the account
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

[#600](https://github.com/unwired-dev/product/issues/600) adds the replacement
client's approval path. Product Sign-In registers a device and its backend
credential independently of possession of Product Sync keys. The client offers
approval only when it holds a published key ring; it never creates a replacement
ring for an initialized account. Convex authenticates the account and device
credential and enforces the current or pending key epoch. It stores opaque
approvals and cannot verify possession of the plaintext ring itself.

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
Length-prefixed info and associated data bind account, target device, request and
key epoch. A backend public-key substitution yields ciphertext it cannot open
without the code, and a forged approval without the code cannot be opened by the
requester. Native decoding also validates the envelope's declared key epoch and
key lengths. This flow uses normal authenticated device access and explicit
code entry; it does not replace or disclose the Recovery Key. The accepted ADRs
require recent authentication for recovery-material replacement and other named
sensitive operations, but do not impose a separate authentication-age limit on
this approval path.

The one-time private key and code live in a device-only Keychain item bound to
account, device and request. The new device saves the adopted ring before removing
that item or acknowledging collection. It receives no Recovery Key or recovery
envelope and cannot initialize or replace the account's existing material.

Requests and approvals each have a 15-minute window. `listPending` and `status`
are mutations used as explicit refresh operations, so each evaluates server time
without Convex query caching. Approval is conditional on an open request, a live
requester, another authenticated device in the same account and the required epoch.
Collection revalidates the approver and required epoch. Removal or revocation of
the approver, or an epoch change before collection, withholds the envelope and
causes the requesting device to renew. Requester removal deletes its requests;
account deletion drains all requests in bounded batches. Successful collection
removes the envelope. Expired envelopes are withheld and removed when superseded,
the requester is removed or the account is deleted.

Refresh is explicit on both devices; pending requests on the approver are kept
only in memory. Google can renew silently, while Apple requires interactive
sign-in after relaunch. Mock journeys use isolated synthetic identities and
controlled transport. Real Keychain and CryptoKit evidence establishes local
encryption boundaries, not deployment JWT verification or two real devices.

## Recovery Key adoption

[#601](https://github.com/unwired-dev/product/issues/601) adds explicit Recovery Key
entry beside trusted-device approval. A malformed key is rejected before renewing
Product Sign-In. Before reading the recovery envelope for a well-formed key, Google
renews its Product Sign-In silently and Apple signs in interactively on every
attempt. The existing subject and Product Account checks fence the renewed
identity, including after relaunch. Reusing an in-process Apple token would strand
retries after expiry and violate [ADR 0001](../adr/0001-end-to-end-encrypted-product-sync.md)'s
recovery authentication requirement.

The existing authenticated, device-scoped query returns only the reserved recovery
envelope. Native CryptoKit opens schema 3 using the entered Recovery Key and the
Product Account binding. Adoption also requires the declared current epoch to
match the ring, its key to exist, and every key to have 32 bytes. Only then does
the device save a published, confirmed vault with the account's existing ring.
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
Recovery saves verified keys before withdrawing that request or removing its local
Keychain item. A crash before the save leaves recovery retryable without keys; a
crash after it leaves the verified ring available across relaunch. Failed remote
withdrawal leaves the request to expire. A stale local enrollment item is ignored
once keys exist. These transport and cleanup changes do not reset encrypted data
or touch provider mail. Losing every key-holding device and the Recovery Key leaves
encrypted product data unrecoverable; this interface offers no reset.

The [qualification record](../qualification/expo-react-native-client.md#recovery-key-evidence-2026-10-04)
records final-tree iOS storage and packaged recovery/enrollment passes after the
initial reviewer corrections, plus a fresh iOS storage pass for the rejection
snapshot fix. The packaged journeys were not rerun for that follow-up. Real
Keychain and CryptoKit checks use a synthetic Convex
boundary; packaged journeys use Mock Mail Sessions. Mac recovery automation and
hosted storage, physical devices and protected Convex and provider qualification
remain pending.

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
Before sending, the native vault durably preserves the generated Recovery Key
and exact transition.
A lost connection, cancellation or ambiguous server response keeps this marker;
a known refusal clears it. Synchronization promotes the preserved Recovery Key
only when the authoritative pending transition matches. A successful idempotent
revocation reply alone proves no adoption: the target may already be revoked
without applying this request. The host emits `revocationNotice: "removed"`
only when the stored Recovery Key matches this removal's generated key after
synchronization; otherwise it emits `unconfirmed` and preserves the confirmed
key. A failed transition read retains the pending marker for the next
synchronization; an authoritative mismatch clears it without promoting the
unapplied key. It durably saves the adopted ring before acknowledging, and
refuses another removal while that
Recovery Key is unconfirmed. Surviving devices open the transition with a held
key and require it to retain every held key. The backend publishes the new
recovery envelope only after every remaining device acknowledges; until then
backup guidance retains the previous key as well as the new one.

Restore and removal attempts use `productAccount:isTrustedDeviceRevoked` before
provider validation or an interactive Product Sign-In prompt. The shared
`RegistrationStore.requireNotRevoked` check prevents failed provider renewal or
prompt cancellation from suppressing a credential-proven revocation.
The query authenticates only the device's revocation rejection, using the
account-scoped tombstone and SHA-256 digest of the credential copied at removal;
it returns one boolean and grants no account data or API access. It needs no
renewable Product Sign-In token, which Apple relaunch cannot supply. Invalid IDs
or a mismatched credential disclose nothing. Transport unavailability retains
local state. A positive rejection removes the account vault, enrollment item and
registration record (including identity and mailbox credentials) before later
provider work. The unrelated encrypted synthetic Inbox fixture has no account
ownership and is outside this purge; future account-owned mail storage must join
this boundary. Purge clears in-memory authorization before reading the persisted
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

### Enrollment scope split

[ADR 0020](../adr/0020-revoke-devices-with-sync-key-rotation.md) and the existing
backend deliberately refuse previously unseen identifiers on any account with a
revocation tombstone. Issue #602's amended criterion requires preventing bypass
through an invented identifier; authorized admission of a legitimate new device
is split into [#750](https://github.com/unwired-dev/product/issues/750), blocked
by #602.

Current replacement enrollment starts after ordinary device registration and
cannot safely override that lock: sign-in alone plus an invented identifier is
not an enrollment authorization. This slice preserves the lock and satisfies
the amended bypass-prevention criterion. The admission protocol and its owning
decision are tracked by #750; they are outside #602's current acceptance scope.
