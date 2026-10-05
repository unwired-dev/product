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
receives the same keys.
[#601](https://github.com/unwired-dev/product/issues/601) lets a device without an
available Trusted Device [unlock with the Recovery Key](#recovering-with-the-recovery-key).
This follows
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
this device**; until then it shows **Unlock private data on this device**. Both
states also offer [Recovery Key entry](#recovering-with-the-recovery-key). Nothing
is reset, and Gmail can still be authorized locally.

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

## Recovering with the Recovery Key

A device that shows **Approve this device** or **Unlock private data on this
device** also shows **Use your Recovery Key**. Enter the written Recovery Key under
**Recovery Key** and choose **Unlock with Recovery Key**. Case, spaces, hyphens and
the look-alikes O, I and L are accepted. Google devices renew their Product Sign-In
silently first. Apple devices ask to sign in with Apple again on every recovery
attempt, so a form left open beyond token expiry can still be retried. The renewed
sign-in must reach the same Product Account.

The device reads the account's recovery envelope from Convex and opens it with the
key. The Recovery Key never leaves the device. Only after the envelope opens does the device save the account
keys, so this device becomes trusted only by successful verification. It then
withdraws its approval request and shows **Private sync is on** with the mailbox
list decrypted from Product Sync. Gmail on this device still needs its own
authorization. The device does not keep or show the Recovery Key afterwards.

A key that is mistyped, incomplete, or belongs to another Product Account unlocks
nothing. The device reports that the Recovery Key does not unlock this Product
Account and retains its existing account keys and encrypted data. A malformed key
is rejected before any sign-in. Otherwise reconnecting may create or renew this
device's approval request before checking the key, and the rejection shows the
current Enrollment Code, not one that request replaced. If the check
cannot reach Convex or is interrupted before the keys are saved, the device stays
waiting, also after relaunch, and the attempt can be repeated. Recovery never
creates replacement keys, changes the recovery envelope or discards product data.
An interruption after verified keys are saved keeps those keys across relaunch.
If withdrawing the approval request fails, the request expires on its own; a stale
local request is ignored once this device holds the keys.

The section also explains that losing every Trusted Device and the Recovery Key
means the encrypted product data cannot be recovered, and that Unwired Mail cannot
unlock it for you. Nothing offers a reset, and mail in Gmail is not affected.

## Keys and envelopes

The native module holds every key; JavaScript receives only status, the Recovery
Key while unconfirmed, and decrypted mailbox addresses.

Sealed records reject altered ciphertext, account, identifier, epoch and schema.
Prototype recovery schemas are never opened. Enrollment keys unlock data only
for the authorized target device and request.

The mailbox descriptor contains the provider and address. Gmail credentials,
access tokens, the Google subject and message content never enter it. Mailbox
credentials stay in the separate device-only registration record.

A device writes its mailbox descriptor only when the record is missing, or when
the stored record opens at the current schema and holds a different descriptor.
Every record it cannot open or decode is read-only. This covers a newer schema,
a key epoch this device lacks and an authentication failure at the current
schema and epoch. The device neither shows nor replaces such a record.

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

Revoking another Trusted Device also requires recent authentication. A
revocation client must send its identity token as the Authorization bearer header on
`POST /trusted-devices/revoke`, and the handler applies the same five-minute
`iat` check as the [sign-in link routes](linked-sign-in.md#identity-boundaries).
The revocation mutation is internal, so callers cannot bypass that check. The
rotated recovery envelope must use the replacement's recovery schema 3; prototype
schemas are rejected.

## Removing a Trusted Device

A device that holds the account keys lists the account's other Trusted Devices
and offers to remove each one. The host first explains the consequences: the
removed device is blocked immediately and the other devices switch to new keys.
Anything a device that stays offline or is compromised already holds cannot be
erased remotely. Confirming starts an interactive Product Sign-In with the
device's own provider, for Google as well as Apple. The fresh token is the bearer
proof for the revocation route.

Removal presents a new Recovery Key until its final group is confirmed. Confirm
and keep this key before removing another device. Keep the previous Recovery Key
until every remaining device has connected and adopted the new keys: during that
interval recovery still uses the previous key, and the new key becomes usable
when rotation completes. New synchronized changes use the new key epoch.
The host reports the removal as complete only after this device has adopted its
own new keys. When another device removed the same device first, or
synchronization could not adopt this removal's new keys, the host reports the
removal as unconfirmed and shows no new Recovery Key. The next synchronization
resolves it.

If a removal applies but its reply is lost, trying to remove that same listed
device again shows the adopted replacement Recovery Key and reports the earlier
removal as complete. It does not remove again or replace that key. Choosing
another device while the earlier removal is unresolved shows the earlier key
without reporting the newly chosen device as removed; confirm the key before
removing that device. An already shown, unconfirmed key likewise stays visible
without a new removal notice or another removal.

Sign-out and reconnect can change a device's listed ID. Repeating removal through
an earlier ID of the same installation returns the existing rotation status;
it does not start another rotation or replace the Recovery Key again.
Removing the current installation through one of its earlier IDs is refused too;
use sign-out to remove the current Trusted Device.

Whichever request first learns that this device was removed purges its local
account keys, enrollment material, identity and mailbox credentials. Every
registration operation with a saved Product Account checks revocation before
renewing or checking the Sign-In Provider grant or opening a provider prompt.
This includes restore, Linked Sign-In, signing in again, switching Sign-In
Providers, Recovery Key unlock and removing another Trusted Device. A failed
provider renewal or cancelled prompt cannot suppress a credential-proven
revocation; the removed device purges before that provider work begins.
An unavailable revocation check retains local state and lets the requested
operation continue with its usual offline or cancellation behavior.
Offline, an Apple relaunch keeps its saved state. The host explains the removal
and that Gmail mail and previously copied offline data are unaffected.

Until [issue #750](https://github.com/unwired-dev/product/issues/750) lands, a fresh
identifier is refused after a removal, including on a legitimate new device. The
app shows "This device cannot join" and saves nothing on that device. Issue #750
will let a new device wait for approval by a Trusted Device or prove the Recovery
Key, then join only after saving the authorized keys. During a pending rotation,
only the replacement Recovery Key will admit a new device; the previous key
continues to serve already-trusted devices until rotation completes. This
admission flow is accepted follow-up work, outside #602. See the
[architecture companion](architecture/private-product-sync.md#device-revocation)
for the implementation boundary and tracked limitations.

Convex rejects record writes and the legacy initialized marker until the recovery
envelope exists. The legacy recovery-material route publishes a first envelope
only for an account that has never had Product Sync material, and successful
publication leaves the account initialized. It answers `409` for an account whose
marker or records predate a missing envelope, because missing keys never reset
silently.

On relaunch the device loads its existing keys and never regenerates them.
With Google, restore refreshes the Product Sign-In, reconnects and reads the
mailbox descriptors back. Native Sign in with Apple cannot renew its identity
token silently. An Apple device therefore uses the token from the current
interactive sign-in for Product Sync, and keeps its local state after relaunch.
Backend reads and writes resume after the next interactive sign-in. The mailbox list last decrypted stays visible, and a mailbox descriptor is marked saved only after this device reads it back. A mailbox connected without a session is
therefore reported as unsaved until then.

Convex reads and writes require the Trusted Device Credential and remain fenced to
its Product Account, as before. A Product Sync failure is logged with its error
domain and code only, and leaves registration and the mailbox usable. When this
device's keys or enrollment request cannot be read, registration responses report
Product Sync as `unavailable`. This includes malformed stored data and key items
saved for another Product Account. The keys are kept, never replaced, and the failure never changes
the saved mailbox state.

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
or Recovery Key visible to the backend. The Recovery Key journey adds a new installation that rejects malformed and
unrelated keys and another account's key and envelope substituted by the backend.
It also stays unchanged after an interrupted attempt and a relaunch. The written
key then gives it the account's key ring and decrypted mailbox list without Gmail
access, withdraws its approval request and leaves the recovery envelope unchanged.
The backend never receives the key. Additional native assertions reject an
authenticated envelope with unusable keys and require fresh Apple authentication
before recovery, rejecting identity changes and cancelled renewal. The Recovery
Key final-tree iOS storage run passed all 19 tests, including those reviewer
assertions. Raw results are retained in `artifacts/private-inbox/integration.zR0adL/`.
That run predates the unreadable local key item case below; with it, the iOS storage
run passed all 20 tests, retained in `artifacts/private-inbox/integration.Z5Nl6g/`.
The read-only mailbox descriptor case below brings the iOS storage run to 21
passing tests, retained in `artifacts/private-inbox/integration.Egerc5/`.
The initial removal implementation added three cases, bringing that suite to
25 passing tests in
`artifacts/private-inbox/integration.xhIHMG/`. The first removes one of two
devices that unlocked with the Recovery Key. The survivor adopts the new epoch and
reads a mailbox saved at it, and the rotation completes with a recovery envelope
that only the new Recovery Key opens. The removed device purges on its next
restore, and its fresh sign-in is refused and keeps nothing. A lost reply makes
the new Recovery Key current only after the next synchronization finds the
removal applied, and a refused removal leaves none. An Apple restore purges only
when the credential-only query reports the revocation and stays usable offline.
The reviewer reran all 25 tests after the restore and backup corrections, with
zero failures in `artifacts/private-inbox/integration.nWUto3/`. That run also
checks that an Apple grant rejection cannot hide an established device removal,
and that another removal cannot replace a Recovery Key awaiting confirmation.
The subsequent reviewer run passed all 25 tests in
`artifacts/private-inbox/integration.CjYdFM/`. It replaces the removed device's
restore attempt in the main removal scenario with a removal attempt while its
Google prompt is configured to cancel: the device purges before opening the
prompt. The Apple credential-only restore and offline assertions remain.
The saved-account prompt regression adds a parameterized test, bringing the
hosted suite to 26 tests. It covers Linked Sign-In, signing in again and switching
Sign-In Providers on Google and Apple, plus Apple Recovery Key unlock. An
unavailable credential check followed by prompt cancellation retains the account;
a proven revocation purges its keys and credentials before any prompt opens.
The reviewer independently reran all 26 tests with zero failures in
`artifacts/private-inbox/integration.uVjPEg/`. The earlier 25-test runs predate
this regression. Packaged journeys were not rerun for this follow-up.
These runs are real native storage and cryptography evidence with a synthetic Convex
boundary.
The two-device approval journey uses two
installations with separate Keychains. A mistyped code, declined, forged, expired,
replayed and revoked approvals all leave the new device without keys. A forged
approval is one sealed without the code. The accepted approval then gives the new
device the account's key ring and decrypted mailbox list, without Gmail access.
The account's recovery envelope and single initialization stay unchanged. It also covers confirmation mismatch and
success, rejection of foreign records, and relaunch with unchanged keys. An
interrupted publication resumes; a device that loses the race discards its keys,
enters enrollment and writes no records. A malformed or mismatched local key item
reports Product Sync as unavailable while Gmail authorization, restore and
sign-in still connect the mailbox, and the item stays unchanged. A mailbox
descriptor with a newer schema, an unknown key epoch or a failed authentication
at the current schema and epoch stays byte-for-byte unchanged and hidden after
sign-in. A readable, different descriptor is replaced and read back.

Convex tests cover single initialization, idempotent retry, refusal for
initialized accounts, epoch and device-proof enforcement, and the reserved
recovery identifier. They also reject record writes and the initialized marker
before publication, and keep accounts left without an envelope from receiving
new key material through either initialization path. Enrollment tests cover one collection per approval, untouched
key material, and refusal of the approval cases listed above. They also cover
expiry and account isolation. Another test shows that a new device of the account reads the recovery
envelope and that another account's device does not. Shared and rendered host tests cover the Recovery Key
confirmation, the mismatch and remount paths, and two synthetic installations that
approve, decline and unlock a new device. They also cover Recovery Key unlock after a
rejected key and an interrupted attempt, the lost-everything explanation and the
absence of any reset action. Removal adds a Convex test showing that only the revoked
device's credential learns of its revocation. It also adds rendered journeys
that remove a device after its explanation and confirm the replacement
Recovery Key, and that explain a removal learned on activation. A shared test
shows that a malformed device list fails native snapshot decoding.
The final reviewer `registration-revocation` and `registration-revoked` Release
Mock Mail journeys each passed on fresh iPhone 18 Pro and iPad Pro 11-inch (M5)
27 simulators, one test per device and scenario with zero failures. Evidence is
retained in `artifacts/expo-bootstrap/native-Sb1WZZ/` and
`artifacts/expo-bootstrap/native-0SbFiJ/`, respectively. The first reviewer
removal attempt caught a confirmation field retaining the previous key's final
group; both hosts now reset the field when the presented key changes, and the
passing removal run includes that correction. These journeys compile the real
bridge but use a synthetic backend; they do not qualify live provider or Convex
revocation. Mac native removal and revoked-device journeys remain deferred.
The registration Mock Mail Sessions use a synthetic Product Sync backend
persisted in the run's Keychain. The packaged Google journey checks the same key
after relaunch, confirms it, and reads the decrypted mailbox list after another
relaunch. The packaged `registration-enrollment` journey signs in to an account
whose keys belong to a synthetic trusted device. It shows the code and checks for
approval. It then reads that device's mailbox through real HPKE and AES-GCM, while
Gmail still needs authorization. The synthetic trusted device reads the code from
the run's Keychain in place of a person typing it. The packaged `registration-recovery`
journey starts from the same account, whose trusted device is lost. It types the
synthetic account's written Recovery Key and reads the mailbox after relaunch.
The Mac journey first types a key with one changed character and sees it rejected. These are deterministic application checks, not real Convex or provider
evidence.

Both packaged journeys passed against the final tree on fresh iPhone 18 Pro and
iPad Pro 11-inch (M5) 27 simulators using a Release build, one test per device
and scenario with zero failures. Recovery evidence is retained in
`artifacts/expo-bootstrap/native-aToLs5/`, and enrollment evidence with the changed
fixture in `artifacts/expo-bootstrap/native-Lt94WW/`. Mac recovery automation and
hosted storage, physical devices and real Convex/Google/Apple recovery remain
unavailable. See the [qualification record](qualification/expo-react-native-client.md#recovery-key-evidence-2026-10-04).

## Protected real qualification

Use signed hosts, a configured Convex development deployment and the
[protected Gmail test tenant](gmail-provider-test-tenant.md). Register a new
account with Google and with Apple on iPhone, iPad and Mac. Confirm the Recovery
Key, connect Gmail and relaunch. Then confirm in the Convex dashboard that the
account has one recovery envelope and opaque `mailbox.` records only. Reopen the
account on a second installation and confirm it shows an Enrollment Code without
creating keys. Approve it from the first device on each Sign-In Provider. Check
that the second device lists the synchronized mailbox before its own Gmail grant.
Check that the Convex dashboard shows the request removed after collection.
On a third installation, unlock with the written Recovery Key instead. Enter a wrong
key first and confirm that it unlocks nothing. Then confirm that the mailbox list
appears and that the account still has one unchanged recovery envelope. Do not record Recovery Keys, tokens or addresses in artifacts. No
real Product Sync pass is claimed until this path has run.
