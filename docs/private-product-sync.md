# Private Product Sync and the Recovery Key

[#599](https://github.com/unwired-dev/product/issues/599) initializes
End-to-End Encrypted Product Sync for a new Product Account on iPhone, iPad and
Mac. It creates the account keys on the first Trusted Device and presents a
user-held Recovery Key. A small real record round-trips through Convex: the
authorized Gmail mailbox descriptor. This follows
[ADR 0001](adr/0001-end-to-end-encrypted-product-sync.md) and
[ADR 0061](adr/0061-separate-product-identity-from-registration-mailbox-authorization.md):
Product Sign-In alone never yields decryption keys, and missing local keys never
create replacement keys.

## What the person sees

After [Google](google-registration.md) or [Apple](apple-registration.md)
registration creates a new Product Account, the registration screen shows
**Save your Recovery Key**. The key is 52 Crockford base32 characters in 13 groups
of four. The copy explains that it is the only way to unlock encrypted product
data if every trusted device is lost, and that it cannot be reset. Gmail
authorization continues as before; the Recovery Key does not block it.

The key stays on screen, across relaunches, until the person enters its final
group under **Last four characters** and chooses **Confirm Recovery Key**. Case,
spaces and the look-alikes O, I and L are accepted. A mismatch keeps the key
visible and explains the error. After confirmation the screen shows **Private sync
is on**, and the key is no longer shown. Showing or replacing it again needs a
recent-authentication flow that belongs to a later slice.

Once Gmail is connected, the section lists the mailbox addresses decrypted from
Product Sync, for example `Encrypted mailbox list: alex@example.invalid.`. The
entry appears only after the device reads the encrypted record back and opens it.

If setup cannot reach Convex, the section reports that it will continue at the
next verification and offers **Sign in again**. Reopening an account that already
has Product Sync keys on a device without them shows **Unlock private data on this
device**. Approval from a trusted device
([#600](https://github.com/unwired-dev/product/issues/600)) and Recovery Key entry
([#601](https://github.com/unwired-dev/product/issues/601)) are the later ways to
unlock it. Nothing is reset, and Gmail can still be authorized locally.

## Keys and envelopes

The native module holds every key; JavaScript receives only status, the Recovery
Key while unconfirmed, and decrypted mailbox addresses. Each Product Account has a
device-only Keychain item (`WhenUnlockedThisDeviceOnly`, not synchronizable, Data
Protection Keychain on Mac). It holds the account key ring, the Recovery Key, the
recovery envelope and the publication and confirmation state.

- **Key ring.** A random 256-bit AES key per epoch, starting at epoch 1. Earlier
  epochs stay in the ring for older records, matching
  [ADR 0020](adr/0020-revoke-devices-with-sync-key-rotation.md) rotation.
- **Records.** AES-GCM-256 with a fresh random 96-bit nonce for every seal.
  The authenticated data binds the Product Account ID, the opaque record
  identifier, the algorithm, the key epoch and the record schema. Convex stores
  only the nonce, ciphertext, tag, key epoch and schema. Changing any stored field,
  moving a record to another identifier or account, or relabelling its epoch fails
  authentication. Records with an unexpected schema are rejected.
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

The mailbox descriptor contains the provider and address. Gmail credentials,
access tokens, the Google subject and message content never enter it. Mailbox
credentials stay in the separate device-only registration record.

## Initialization and relaunch

`productAccount:connect` reports whether the Product Account already has Product
Sync material. A device creates keys only when Convex reports it has none and this
device holds no keys for the account. It saves the keys locally before publishing
anything, so an interrupted attempt resumes with the same keys.

`productSync:initialize` stores the first recovery envelope and marks the account
initialized in one mutation. It requires the authenticated Trusted Device proof
and the current key epoch. It returns `initialized: false` when the account
already has other material, so exactly one device wins. Repeating the winning
envelope after a lost response succeeds without another write. A device that
loses discards its unpublished keys, which have protected nothing, and needs
enrollment. No record is written before publication succeeds. The legacy
recovery-material replacement route still requires recent authentication.

On relaunch the device loads its existing keys and never regenerates them.
With Google, restore refreshes the Product Sign-In, reconnects and reads the
mailbox descriptors back. Native Sign in with Apple cannot renew its identity
token silently. An Apple device therefore uses the token from the current
interactive sign-in for Product Sync, and keeps its local state after relaunch.
Backend reads and writes resume after the next interactive sign-in.

Convex reads and writes require the Trusted Device Credential and remain fenced to
its Product Account, as before. A Product Sync failure is logged without details
and leaves registration and the mailbox usable.

## Deterministic evidence

The hosted native storage suite (`native/private-inbox/integration/test.zsh`)
runs the real Keychain, CryptoKit and registration store against a synthetic
Convex boundary that enforces single initialization and compare-and-set records.
It checks:

- nonce freshness;
- rejection of tampered ciphertext, nonce, tag and algorithm, and of another
  account, identifier, schema or relabelled epoch;
- rejection of another account's keys and of prototype recovery schemas;
- recovery and enrollment envelopes that open only for their key, account,
  device and request.

It covers one-time initialization, the Recovery Key opening the published
envelope, and an encrypted descriptor round trip with no address, subject, token
or Recovery Key visible to the backend. It also covers confirmation mismatch and
success, rejection of foreign records, and relaunch with unchanged keys. An
interrupted publication resumes; a device that loses the race discards its keys,
enters enrollment and writes no records.

Convex tests cover single initialization, idempotent retry, refusal for
initialized accounts, epoch and device-proof enforcement, and the reserved
recovery identifier. Shared and rendered host tests cover the Recovery Key
confirmation, the mismatch and remount paths, and the enrollment-needed state.
The registration Mock Mail Sessions use a synthetic Product Sync backend
persisted in the run's Keychain. The packaged Google journey checks the same key
after relaunch, confirms it, and reads the decrypted mailbox list after another
relaunch. These are deterministic application checks, not real Convex or provider
evidence.

## Protected real qualification

Use signed hosts, a configured Convex development deployment and the
[protected Gmail test tenant](gmail-provider-test-tenant.md). Register a new
account with Google and with Apple on iPhone, iPad and Mac. Confirm the Recovery
Key, connect Gmail and relaunch. Then confirm in the Convex dashboard that the
account has one recovery envelope and opaque `mailbox.` records only. Reopen the
account on a second installation and confirm it reports enrollment without
creating keys. Do not record Recovery Keys, tokens or addresses in artifacts. No
real Product Sync pass is claimed until this path has run.
