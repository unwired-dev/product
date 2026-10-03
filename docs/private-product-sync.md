# Private Product Sync and the Recovery Key

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/private-product-sync.md).

[#599](https://github.com/unwired-dev/product/issues/599) initializes
End-to-End Encrypted Product Sync for a new Product Account on iPhone, iPad and
Mac. It creates the account keys on the first Trusted Device and presents a
user-held Recovery Key. A small real record round-trips through Convex: the
authorized Gmail mailbox descriptor.
[#600](https://github.com/unwired-dev/product/issues/600) lets an existing
Trusted Device [approve a new device](#approving-a-new-device), which then
receives the same keys. This follows
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
has Product Sync keys on a device without them never creates keys. Once that device
reaches Convex it asks for [approval](#approving-a-new-device) and shows **Approve
this device**; until then it shows **Unlock private data on this device**. Recovery
Key entry ([#601](https://github.com/unwired-dev/product/issues/601)) is the other
way to unlock it. Nothing is reset, and Gmail can still be authorized locally.

## Approving a new device

Product Sign-In on another device reaches the Product Account but none of its
private data. That device shows **Approve this device** with a one-time
[Enrollment Code](domain/identity.md) of 56 Crockford base32 characters in fourteen
groups. Copy it or enter it on the trusted device. The code stays on the device; Convex never receives it.

On a Trusted Device that holds the keys, **Check for a new device** lists the
newest request. **Approve a new device** names the requesting device and asks for
**Code from the new device**. Case, spaces and the look-alikes O, I and L are
accepted. The last character is a check digit. An invalid check digit is reported on
the trusted device and nothing is sent. A different code with a valid check digit
cannot unlock the requesting device. **Decline** cancels the request.

On the new device, **Check for approval** collects the approval. The device adopts
the account keys and shows **Private sync is on** with the mailbox list decrypted
from Product Sync. Gmail on that device still needs its own authorization, and
the Recovery Key stays with the device that created it. A request expires after
15 minutes, and an approval must be collected within 15 minutes. When a request
expires or is declined, the new device shows a new code. When an approval does
not open on this device, the device says nothing was unlocked and shows a new code.

Google devices renew their Product Sign-In silently for both checks. An Apple
device uses its current interactive sign-in. After a relaunch, either check asks
it to sign in with Apple again.

Convex refuses an approval when the request:

- is replayed or already approved;
- has expired, was declined, or was replaced by a newer request from the same device;
- comes from a revoked or removed device;
- was approved by a device that has since been revoked or removed;
- names another device than the one that asked;
- is approved by the device that asked;
- uses a key epoch that is not current, including one superseded before collection.

None of these change the account's keys or recovery envelope. Removing a device
deletes its requests, and deleting the Product Account deletes them all.

The backend never receives the Enrollment Code, account keys, or the one-time
private key. Each check evaluates expiry on the server anew. The approval is
removed after collection; an expired approval is never returned. The native module
keeps the code and private key in device-only storage until this device holds the
keys. [Protocol details](architecture/private-product-sync.md#trusted-device-enrollment)
are maintained in the architecture companion.

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
  device, request, key epoch and Enrollment Code, and Enrollment Code parsing
  with its check digit.

It covers one-time initialization, the Recovery Key opening the published
envelope, and an encrypted descriptor round trip with no address, subject, token
or Recovery Key visible to the backend. The two-device approval journey uses two
installations with separate Keychains. A mistyped code, declined, forged, expired,
replayed and revoked approvals all leave the new device without keys. A forged
approval is one sealed without the code. The accepted approval then gives the new
device the account's key ring and decrypted mailbox list, without Gmail access.
The account's recovery envelope and single initialization stay unchanged. It also covers confirmation mismatch and
success, rejection of foreign records, and relaunch with unchanged keys. An
interrupted publication resumes; a device that loses the race discards its keys,
enters enrollment and writes no records.

Convex tests cover single initialization, idempotent retry, refusal for
initialized accounts, epoch and device-proof enforcement, and the reserved
recovery identifier. Enrollment tests cover one collection per approval, untouched
key material, and refusal of the approval cases listed above. They also cover
expiry and account isolation. Shared and rendered host tests cover the Recovery Key
confirmation, the mismatch and remount paths, and two synthetic installations that
approve, decline and unlock a new device.
The registration Mock Mail Sessions use a synthetic Product Sync backend
persisted in the run's Keychain. The packaged Google journey checks the same key
after relaunch, confirms it, and reads the decrypted mailbox list after another
relaunch. The packaged `registration-enrollment` journey signs in to an account
whose keys belong to a synthetic trusted device. It shows the code and checks for
approval. It then reads that device's mailbox through real HPKE and AES-GCM, while
Gmail still needs authorization. The synthetic trusted device reads the code from
the run's Keychain in place of a person typing it. These are deterministic application checks, not real Convex or provider
evidence.

## Protected real qualification

Use signed hosts, a configured Convex development deployment and the
[protected Gmail test tenant](gmail-provider-test-tenant.md). Register a new
account with Google and with Apple on iPhone, iPad and Mac. Confirm the Recovery
Key, connect Gmail and relaunch. Then confirm in the Convex dashboard that the
account has one recovery envelope and opaque `mailbox.` records only. Reopen the
account on a second installation and confirm it shows an Enrollment Code without
creating keys. Approve it from the first device on each Sign-In Provider. Check
that the second device lists the synchronized mailbox before its own Gmail grant.
Check that the Convex dashboard shows the request removed after collection. Do not record Recovery Keys, tokens or addresses in artifacts. No
real Product Sync pass is claimed until this path has run.
