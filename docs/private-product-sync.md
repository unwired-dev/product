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
[#750](https://github.com/unwired-dev/product/issues/750) makes every device after
an account's first a Pending Device until one of those two admits it.
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
has Product Sync keys on a device without them never creates keys. A device that
signs in to an existing account waits as a [Pending Device](#approving-a-new-device).
A Trusted Device that lost its local keys shows **Unlock private data on this
device** and offers [Recovery Key entry](#recovering-with-the-recovery-key), or
signing out and in again so another device can approve it. Nothing is reset.

## Approving a new device

Product Sign-In admits only the device that creates the account's keys. Every
later device, on every account, signs in as a
[Pending Device](domain/identity.md). It reaches the Product Account but none of
its data: no account operations, Product Sync reads or push routing, and no Gmail
authorization. Its screen, **Add this device**, explains that an existing device
or the Recovery Key must authorize it. It shows **Approve this device** with a
one-time [Enrollment Code](domain/identity.md) of 56 Crockford base32 characters in
fourteen groups, **Check for approval**, **Use your Recovery Key**, sign-out and
**Delete Product Account**. Copy the code or enter it on the trusted device. The
code stays on the device; Convex never receives it. A Pending Device can delete
the Product Account only after a recent interactive Product Sign-In.

On a Trusted Device that holds the keys, **Check for a new device** lists the
newest request. **Approve a new device** names the requesting device and asks for
**Code from the new device**. Case, spaces and the look-alikes O, I and L are
accepted. The last character is a check digit. An invalid check digit is reported on
the trusted device and nothing is sent. A different code with a valid check digit
cannot unlock the requesting device. **Decline** cancels the request. The approving
device seals the account's newest key epoch; while a removal's rotation is pending,
it adopts the new epoch first.

On the new device, **Check for approval** collects the approval. The device stores
the account keys and then confirms them; only that confirmation makes it a Trusted
Device, already at the approval's key epoch. It shows **Private sync is on** with
the mailbox list decrypted from Product Sync, and **Authorize Gmail** appears.
Gmail on that device still needs its own authorization, and the Recovery Key stays
with the device that created it. If the approving device is removed, or a removal
supersedes the approved key epoch, before the new device confirms, the approval is
void: the new device discards the keys it stored, stays pending and shows a new
code.

A request and its code expire after 15 minutes, and an approval must be collected
within 15 minutes. The Pending Device ends with its code; signing in again or
**Check for approval** starts a new one with a new code. When a request expires or
is declined, the new device shows a new code. When an approval does not open on
this device, the device says nothing was unlocked and shows a new code. An
installation has at most one Pending Device, and a Product Account at most three
at a time. The Trusted Device limit applies when a device is admitted.

Google devices renew their Product Sign-In silently for both checks. An Apple
device uses its current interactive sign-in. After a relaunch, either check asks
it to sign in with Apple again.

Convex refuses an approval when the request:

- is replayed or already approved;
- has expired, was declined, or was replaced by a newer request with another key;
- belongs to another Product Account or to a device that was admitted or signed out;
- comes from an approving device that does not hold the account's newest key epoch;
- uses a key epoch that is not current, including one superseded before collection.

An approval whose approving device was later removed opens nothing. None of these
change the account's keys or recovery envelope. Deleting the Product Account deletes
every Pending Device.

The backend never receives the Enrollment Code, account keys, or the one-time
private key. Each check evaluates expiry on the server anew. The approval is
removed with the Pending Device at admission; an expired approval is never
returned. The native module
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

A Pending Device proves the key with a value derived from it for that purpose
only. Convex compares the value's digest with the verifier published with the
recovery envelope, and only on a match returns the envelope. The device opens it
with the key, saves the account keys and confirms them, and only then becomes a
Trusted Device. A Trusted Device that lost its keys reads its account's envelope
directly. The Recovery Key never leaves the device, and only after the envelope
opens does the device save the account keys. The device shows **Private sync is
on** with the mailbox list decrypted from Product Sync, and **Authorize Gmail**
appears. Gmail on this device still needs its own authorization. The device does
not keep or show the Recovery Key afterwards.

While a removal's key rotation is pending, only the replacement Recovery Key that
the removal issued admits a Pending Device, at the new key epoch. The previous
Recovery Key keeps working for devices that are already trusted until rotation
completes, but admits no new device. A person who loses every Trusted Device while
holding only the previous Recovery Key during that interval cannot regain access;
deleting the Product Account is the only path left.

A key that is mistyped, incomplete, or belongs to another Product Account unlocks
nothing. The device reports that the Recovery Key does not unlock this Product
Account and retains its existing account keys and encrypted data. A malformed key
is rejected before any sign-in. Otherwise reconnecting may create or renew this
device's approval request before checking the key, and the rejection shows the
current Enrollment Code, not one that request replaced. If the check
cannot reach Convex or is interrupted before the device is admitted, it stays
waiting, also after relaunch, and the attempt can be repeated; a device that
saved the keys confirms them on its next check. Recovery never creates replacement
keys, changes the recovery envelope or discards product data.

The section also explains that losing every Trusted Device and the Recovery Key
means the encrypted product data cannot be recovered, and that Unwired Mail cannot
unlock it for you. Nothing offers a reset, and mail in Gmail is not affected.

## Keys and envelopes

The native module holds every key; JavaScript receives only status, the Recovery
Key while unconfirmed, and decrypted mailbox addresses.

Sealed records reject altered ciphertext, account, identifier, epoch and schema.
Prototype recovery schemas are never opened. Enrollment keys unlock data only
for the authorized Pending Device and its current one-time key. The first device,
a Recovery Key replacement and a removal each publish the Recovery Key verifier
with the recovery envelope they write.

Each [Mailbox Connection](gmail-inbox.md#gmail-mailboxes) has a private synchronized
description containing its provider and address, including whether it was removed.
Gmail credentials, access tokens, the Google subject and message content never
enter it. Mailbox credentials stay on each authorized device.

Every description a device cannot open or decode is read-only. This includes
newer formats, missing keys and failed authentication. The device neither shows
nor replaces it, and an unreadable description cannot acknowledge a removal.

Removing a connection waits on this device until its synchronized removal is
confirmed, or fresh authorization on another device has already superseded that
removal. Other Trusted Devices purge the removed connection's credential and
cache before further Gmail access. Interrupted local cleanup remains visible as
unfinished mailbox changes and retries after relaunch; it never reopens the
removed connection. Adding the same mailbox back requires fresh consent and
invalidates authorization from before its removal, including when the earlier
removal had not reached private sync yet. An addition authorized without private
sync cannot later recreate a removal or adopt a different incarnation just by restoring; the person authorizes it
again after that removal is learned. Two devices adding the same mailbox at the same
time converge on one synchronized description; neither loses its authorization
unless a later removal supersedes that addition. Offline restore does not extend
earlier authorization to that later connection. A mailbox authorized while private
sync is unreachable keeps its authorization when the synchronized description is still
the one this device last read. An unseen description cannot prove that no removal
occurred meanwhile and requires fresh authorization. A description written
before connections had incarnations belongs to the same connection. The decrypted
mailbox list omits removals.

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
interval an already-trusted device still recovers with the previous key, and a new
device is admitted only with the new key. New synchronized changes use the new key
epoch.
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
use [sign-out](account-removal.md) to remove the current Trusted Device.

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

A removed device's own installation identifier and Trusted Device Credential stay
refused with **This device was removed**. A fresh sign-in mints a new identifier,
which is an ordinary [Pending Device](#approving-a-new-device): it never receives a
rotation transition, a recovery envelope or a newer key epoch unless a Trusted
Device approves it or the replacement Recovery Key unlocks it. A removed device
with a live Product Sign-In can still delete the Product Account's synchronized
data, but it can read none of it. See the
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
  Pending Device, key epoch and Enrollment Code, and Enrollment Code parsing
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
fixture in `artifacts/expo-bootstrap/native-Lt94WW/`. That 2026-10-04 run left Mac recovery automation and
hosted storage, physical devices and real Convex/Google/Apple recovery
unavailable; the #750 evidence below records the later mocked Mac journeys. See the [qualification record](qualification/expo-react-native-client.md#recovery-key-evidence-2026-10-04).

Pending Device admission ([#750](https://github.com/unwired-dev/product/issues/750))
updates the hosted storage suite's synthetic Convex boundary to admit only the
device that created an account's keys and to check Recovery Key proofs against
the published verifier. Its journeys cover a second device that waits without
Gmail authorization until it is approved or unlocked. They also cover approvals
that do not open or become void after a removal, the previous Recovery Key
admitting nobody during and after a rotation, a removed device returning as a
Pending Device, and a Pending Device signing out. Reviewer regressions cover an
older saved ring receiving a newer approval, sign-out after a lost admission
reply, and deletion with an expired pending proof or one removed by cleanup.
All 33 tests passed on a fresh iOS 27 simulator in
`artifacts/private-inbox/integration.vTM2gi/`, superseding the implementation's
31-test run in `artifacts/private-inbox/integration.7a8VQx/`.

The packaged `registration-revoked`, `registration-enrollment`,
`registration-recovery` and `registration-removal` journeys each passed one test
with zero failures on fresh iPhone 18 Pro and iPad Pro 11-inch (M5) 27 simulators
using Release builds. The revoked journey shows the removal notice, then the
enrollment gate after a fresh sign-in, and signs out of it.

| Journey                   | iPhone evidence under `artifacts/expo-bootstrap/` | iPad evidence under `artifacts/expo-bootstrap/` |
| ------------------------- | ------------------------------------------------- | ----------------------------------------------- |
| `registration-revoked`    | `native-AG36Jy/`                                  | `native-DuEzHg/`                                |
| `registration-enrollment` | `native-P4MuAT/`                                  | `native-Zk76B0/`                                |
| `registration-recovery`   | `native-p1KnHK/`                                  | `native-WrhuYr/`                                |
| `registration-removal`    | `native-ddBzuM/`                                  | `native-WeJpsZ/`                                |

The removal journey is rechecked after the final pending-proof renewal fix;
its final iPhone evidence is `artifacts/expo-bootstrap/native-SqERao/` and
iPad evidence is `artifacts/expo-bootstrap/native-h3mwYW/`. Mac Testing builds with the mock-only profile passed the
same four scenarios; evidence under
`artifacts/macos-inbox/` is `journey.7fgoBs/`, `journey.PFkPOE/`, `journey.80OM1J/`, `journey.6788hv/`
in that scenario order. The Mac variant of hosted storage,
physical devices and protected real Convex/Google/Apple/APNs qualification remain
deferred. These are synthetic-backend checks, not live Convex or provider evidence.

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
