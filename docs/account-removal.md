# Sign-out and Product Account deletion

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/account-removal.md).

[#603](https://github.com/unwired-dev/product/issues/603) lets the replacement
hosts on iPhone, iPad and Mac sign the current device out, or permanently delete
the Product Account. The two actions are separate and are confirmed separately.
Neither one deletes mail in Gmail. Neither is the one-time administrative reset of
the development deployment that
[cutover #627](https://github.com/unwired-dev/product/issues/627) owns. The apps
offer no reset.

## What the person sees

Every signed-in registration screen ends with **This device and your account**.
It offers **Sign out of this device** and **Delete Product Account**. The first
press of either one only explains what it does and offers **Cancel**.

**Sign out of this device** explains that this device leaves the Product Account
and loses its account data, keys and mailbox access. The person's other devices
and their Gmail mail are unaffected. Pressing **Sign out of this device** again
unregisters this Trusted Device and its push routes, then removes the account
from this device. Save and confirm any Recovery Key shown before signing out;
an unconfirmed key keeps its backup screen and prevents sign-out. The screen
returns to **Welcome to Unwired Mail**. Google
renews its Product Sign-In silently for this. Sign in with Apple cannot, so an
Apple device asks to sign in with Apple again, and that must be the same Apple
ID. To use the device again, sign in and approve it from a Trusted Device or
with the Recovery Key. Signing in again never makes up new keys.

**Delete Product Account** explains that deletion is permanent and reaches every
device. Mail stays in Gmail, and the authorization given to Google is not
revoked. **Delete permanently** starts an interactive Product Sign-In:

- If Sign in with Apple opens the account, the device asks for Sign in with Apple.
  This holds whether Apple created the account or is linked to it, and lets Convex
  revoke the Apple authorization.
- Otherwise the device asks to sign in with Google.

Convex accepts that sign-in only when it is at most five minutes old and opens
this Product Account. The device then shows **Product Account deleted** and keeps
nothing of the account.

Sign-out and deletion need a connection. When the sign-in is cancelled, nothing
changes and no message appears. A failed request retains local account data;
its remote outcome may be unknown if the reply was lost. The screen asks the
person to retry the same removal, without promising that nothing was removed.
After relaunch, **Finish signing out** or **Confirm account deletion** offers that
retry and withholds mailbox, linking and sign-in work. An unanswered sign-out
never silently reconnects the device. Once removal is acknowledged, any
interrupted local cleanup resumes on relaunch without provider authentication.
A deletion whose reply was lost is reported as complete when repeated.

Convex can refuse a deletion before it removes anything. That happens when the
sign-in is stale, when it belongs to another account, or when it is a Google
sign-in for an account Sign in with Apple also opens. A refused first attempt leaves
the account open, not pending, and the screen says nothing was deleted. A refusal
after an earlier unanswered attempt keeps deletion pending: the account may already
be deleted, so retry to confirm it and finish local cleanup. After an Apple link
this device had not seen, the next attempt asks for Sign in with Apple.

## What is removed

On this device, sign-out and deletion remove:

- the saved Product Sign-In and the Gmail mailbox credential;
- the Product Sync keys, any held Recovery Key and the decrypted mailbox list;
- any open device-approval request;
- the encrypted [Gmail Inbox cache](gmail-inbox.md);
- the session state of this launch.

The next Product Account on the device starts from nothing. The replacement has
no Drafts yet; the preview Inbox fixture is test-only and is not account data.
Later slices must add their stores to this purge.

Once deletion is authorized, Convex blocks every Product Account, Product Sync,
device and push request for the account and finishes removing backend data after
interruptions. Neither the original nor a Linked Sign-In can reopen the account
or create a new one. A recent authenticated retry can finish an already-authorized
deletion even after cleanup removed its requesting device.

A reachable device purges the account the next time it reaches Convex. A Google
device does so on restore. An Apple device does so on its next interactive sign-in
or backend request, because an Apple relaunch does not reconnect. The device then
shows **Product Account deleted**. Data copied from a device that stays offline or
is compromised cannot be erased remotely.

## Backend interface

Hosts delete through `POST /product-account/delete` on the deployment's
`.convex.site` host. The identity token from the fresh sign-in is the
`Authorization` bearer. The JSON body carries:

- `trustedDeviceId` and `trustedDeviceCredential`, the device proof;
- with Sign in with Apple only, the `authorizationCode` and the host's bundle ID
  as `appleClientId`.

The route applies the same five-minute `iat` check as the
[sign-in link routes](linked-sign-in.md#identity-boundaries). It responds as
follows:

| Status | Meaning                                                                 |
| ------ | ----------------------------------------------------------------------- |
| 200    | `{ deleted }`; `false` means cleanup continues in the background        |
| 400    | The body is malformed                                                   |
| 401    | The sign-in is stale or missing                                         |
| 403    | The Trusted Device proof failed                                         |
| 409    | An account that Sign in with Apple opens was asked without Apple's code |

The existing `productAccountDeletion:deleteProductAccount` action still requires an
Apple authorization code; the Swift prototype uses it. Sign-out calls
`productAccount:unregisterTrustedDevice`.

## Deterministic evidence

Convex tests drive the route with authenticated test identities and synthetic
bearer tokens. They check:

- stale tokens and missing device proofs are rejected and change nothing;
- a Google-only account is deleted and fenced from reconnecting;
- repeating a deletion reports it complete;
- Google and Apple without a code are refused for an account Apple also opens;
- the Apple path with a code deletes the account and its Linked Sign-Ins.

Shared store and rendered host tests check:

- both confirmations, including cancellation;
- failed sign-out and deletion retain the local account snapshot and explain the uncertain outcome;
- pending removal after relaunch offers its retry without mailbox or sign-in work;
- a cancelled sign-in stays quiet;
- deletion reaches another installation on its next verification;
- a deleted account cannot be reopened.

The hosted native storage suite (`native/private-inbox/integration/test.zsh`) runs
these with the real Keychain and synthetic backends:

- An offline sign-out changes nothing. A successful one unregisters this
  installation first and then holds no registration, keys or approval request.
- An unconfirmed Recovery Key prevents sign-out.
- Another Product Account signing in afterwards sees no earlier mailbox list or
  Recovery Key.
- Apple sign-out asks Apple again and refuses another Apple ID.
- Deletion uses an interactive sign-in. Cancelled or unreachable attempts keep
  everything.
- Another Google device purges on its next restore, and signing in again keeps nothing.
- For both providers, an unanswered removal remains unavailable across relaunch
  until retried; acknowledged partial cleanup finishes before provider prompts.
- An account Sign in with Apple also opens sends Apple's code.
- A refused first attempt clears the pending state; a refused retry preserves
  earlier uncertainty and cannot reopen account access. Another identity of the same
  provider is rejected before any request. An unseen Apple link moves the next
  attempt to Apple.

The implementer's iOS run passed its earlier 29-test suite in
`artifacts/private-inbox/integration.ddqPp6/`. It predates the reviewer fixes.
The reviewer ran the corrected 30-test suite in
`artifacts/private-inbox/integration.rhDjQS/`, including the pending-removal
presentation and interrupted cleanup checks. With the refused-deletion fix the
30-test suite passed in `artifacts/private-inbox/integration.f6nCfj/`. Earlier reviewer runs in
`artifacts/private-inbox/integration.KHkhDD/` predate the final presentation field.

The round-2 reviewer ran the corrected 30-test suite in
`artifacts/private-inbox/integration.NpXma7/`. It adds refused-retry checks after
an applied deletion loses its reply and the device-revocation check is unavailable,
for both Google and Apple. Those retries retain pending deletion across relaunch;
fresh refusals still leave the account usable. The boundary remains synthetic;
the suite exercises the real native store and Keychain.

The `registration-removal` [Mock Mail Session](mock-mail-sessions.md) journey
signs out, relaunches, signs in again to an approval request, deletes the account,
relaunches and finds the account deleted. It passed on the iPhone and iPad 27
simulators on the final reviewed code in
`artifacts/expo-bootstrap/native-CaVSw7/`. The earlier reviewer run
`artifacts/expo-bootstrap/native-ur87w2/` predates equivalent JSX rendering
consolidation and copy declaration ordering; the implementer run
`artifacts/expo-bootstrap/native-oEPX7B/` predates the reviewer fixes.
The Mac journey is deferred: XCTest could not activate the app while the local
Mac's screen was locked. The original Testing build predates the reviewer fixes;
fresh CocoaPods preparation failed with `path name contains null byte`, and
compilation of the existing workspace could not resolve React or GoogleSignIn.
The corrected non-mock iOS Release build passed in
`artifacts/mock-mail-production-reviewer/`; the normal Mac JavaScript bundle and
its renderer/autolinking checks also passed. Real Google
and Apple deletion against a deployment, and Apple's revocation response, remain
pre-release checks.
