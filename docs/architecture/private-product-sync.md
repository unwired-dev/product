# Private product sync: architecture notes

Reviewer-only companion to [docs/private-product-sync.md](../private-product-sync.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Keys and envelopes

Each Product Account has a
device-only Keychain item (`WhenUnlockedThisDeviceOnly`, not synchronizable, Data
Protection Keychain on Mac). It holds the account key ring, the Recovery Key, the
recovery envelope and the publication and confirmation state.

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
  the key ring to one enrolling device's public key. The HPKE info and
  authenticated data bind the Product Account, target device and enrollment
  request. #600 owns its transport, approval and device-key storage; this slice
  defines and tests the envelope only.

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
