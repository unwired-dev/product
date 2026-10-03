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
device receives only the key ring.

- **Key ring.** A random 256-bit AES key per epoch, starting at epoch 1. Earlier
  epochs stay in the ring for older records, matching
  [ADR 0020](../adr/0020-revoke-devices-with-sync-key-rotation.md) rotation.
- **Records.** AES-GCM-256 with a fresh random 96-bit nonce for every seal.
  The authenticated data binds the Product Account ID, the opaque record
  identifier, the algorithm, the key epoch and the record schema. Convex stores
  only the nonce, ciphertext, tag, key epoch and schema, plus its own row metadata
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
