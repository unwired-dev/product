# Private Product Sync and the Recovery Key

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/private-product-sync.md).

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

If setup cannot reach Convex, the section reports that it will continue the next
time this device reconnects its Product Account to Convex. That happens on a Google
restore or any interactive sign-in, and the section offers **Sign in again** to do it
now. A connected mailbox whose descriptor has not been read back yet, for example
one chosen after an Apple relaunch, shows that it is not saved to private sync yet
and offers the same action. Signing in again rechecks a saved Gmail mailbox instead
of restarting Gmail consent. Reopening an account that already
has Product Sync keys on a device without them shows **Unlock private data on this
device**. Approval from a trusted device
([#600](https://github.com/unwired-dev/product/issues/600)) and Recovery Key entry
([#601](https://github.com/unwired-dev/product/issues/601)) are the later ways to
unlock it. Nothing is reset, and Gmail can still be authorized locally.

## Keys and envelopes

The native module holds every key; JavaScript receives only status, the Recovery
Key while unconfirmed, and decrypted mailbox addresses.

Sealed records reject altered ciphertext, account, identifier, epoch and schema.
Prototype recovery schemas are never opened. Enrollment keys unlock data only
for the authorized target device and request.

The mailbox descriptor contains the provider and address. Gmail credentials,
access tokens, the Google subject and message content never enter it. Mailbox
credentials stay in the separate device-only registration record.

## Initialization and relaunch

Account connection reports whether Product Sync material already exists. A device creates keys only when Convex reports it has none and this
device holds no keys for the account. It saves the keys locally before publishing
anything, so an interrupted attempt resumes with the same keys. A receipt saved
before this slice reports no state; it shows setup as pending, never enrollment,
and creates no keys until the next connect reports the account's state. Read all record pages before reporting complete synchronization.

Exactly one device can initialize Product Sync. Repeating the winning publication
after a lost response succeeds without replacing its keys. A competing device
discards only its unpublished keys, needs enrollment and writes no records before
publication succeeds. Replacing recovery material requires recent authentication.

On relaunch the device loads its existing keys and never regenerates them.
With Google, restore refreshes the Product Sign-In, reconnects and reads the
mailbox descriptors back. Native Sign in with Apple cannot renew its identity
token silently. An Apple device therefore uses the token from the current
interactive sign-in for Product Sync, and keeps its local state after relaunch.
Backend reads and writes resume after the next interactive sign-in. The mailbox list last decrypted stays visible, and a mailbox descriptor is marked saved only after this device reads it back. A mailbox connected without a session is
therefore reported as unsaved until then.

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
