# Apple registration and Gmail authorization

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/apple-registration.md).

[#597](https://github.com/unwired-dev/product/issues/597) adds Sign in with Apple
as a second Product Sign-In choice on iPhone, iPad and Mac. It follows
[ADR 0061](adr/0061-separate-product-identity-from-registration-mailbox-authorization.md):
Apple identifies the Product Account only. Registration continues straight into the
existing [resumable Gmail authorization](google-registration.md). The onboarding
copy says Apple sign-in does not give access to mail. No connected Inbox appears
until a Google account grants Gmail access and passes Gmail verification.

## Identity boundaries

Product Accounts stay keyed by the verified issuer and subject. An Apple identity
and a Google identity are separate Product Accounts even when their email addresses
match. The Gmail mailbox authorized after Apple sign-in is a Mailbox Connection, not
a Linked Sign-In. Its Google identity never reaches Convex. Only
[explicit linking](linked-sign-in.md) lets Google open the same account. On a
device with a committed Product Account, sign-in through a provider that is not
linked is rejected rather than switching or merging accounts.

Apple may return a private relay address. The native adapter keeps it in the
device-only registration record and shows it as the account's contact email. It
is display and contact information only. It is never used as a Google account
hint, never selects or verifies a mailbox and is not stored by Convex. The Gmail
session after Apple sign-in starts without a Google account hint.

## Native verification and restore

Native Sign in with Apple cannot renew an identity token without user interaction.
A pending [sign-out or deletion](account-removal.md) takes precedence: unanswered
removal offers only its retry, and acknowledged cleanup resumes before any
provider verification.
Restore and Gmail authorization first check whether this Trusted Device was
removed from its Product Account, then check the Apple credential state for
the saved subject instead of reconnecting to Convex. A revoked, missing or
unverifiable credential keeps the Product Account and mailbox-setup record. The
host then reports that the account could not be verified and offers Sign in again
with Apple. A positive
[Device Revocation](private-product-sync.md#removing-a-trusted-device) result
purges the account even when the Apple grant is unavailable. Offline, it keeps
the saved account. Backend operations that need a current Apple token must reauthenticate
interactively or add a server-side token exchange. [Private Product Sync](private-product-sync.md#initialization-and-relaunch)
uses the token from the current interactive sign-in and keeps its local state on relaunch.

Cancelling the Apple sheet returns to the previous status without an error.
If Convex does not confirm a new Apple registration, the record keeps the
subject and installation ID. Restore reports Product Sign-In as the remaining
step, and signing in with the same Apple ID resumes it. A record that never received a Product Account may
be replaced by another Sign-In Provider. Once registration completes, Gmail
cancellation, decline, missing Gmail and interruption keep it. The host reports
the Gmail step as remaining, exactly as for Google registration.

## Configure the hosts

Both hosts use the bundle ID `dev.unwired.mail`. Enable Sign in with Apple for
that App ID on iOS and macOS. The Expo config
declares the entitlement for generated iOS projects. The Mac entitlements file declares
it for signed builds. Every development profile used to sign the Mac `Testing` build
must include the capability. Ad-hoc Mac builds compile, but the system rejects
Apple authorization without the entitlement; the host logs that failure without
credentials.

Native Apple authorization uses the system sheet and has no redirect URL or URL
scheme. Google still needs its reversed client-ID URL scheme and configured
`UNWIRED_GOOGLE_CLIENT_ID` for the Gmail step. Apple-first registration therefore
needs the same [Google host configuration](google-registration.md#configure-the-hosts).

`APPLE_BUNDLE_ID` on the Convex deployment names the hosts' token audience,
`dev.unwired.mail`, which the Swift prototype shares. It has no default: a
deployment without `APPLE_BUNDLE_ID` or `APPLE_PRODUCT_CLIENT_IDS` accepts no Apple
token. Set `APPLE_PRODUCT_CLIENT_IDS` only to accept further comma-separated bundle
IDs, then deploy the auth configuration. These are public token audiences.

[Product Account deletion](account-removal.md) exchanges and revokes Apple
authorization with the client that issued it. A host passes its bundle ID as `appleClientId`, which must be one of
the configured audiences; without it, deletion requires `APPLE_BUNDLE_ID`. All configured bundle IDs
share the deployment's Sign in with Apple key (`APPLE_SIGN_IN_KEY_ID`,
`APPLE_SIGN_IN_PRIVATE_KEY` and `APPLE_TEAM_ID`), so they must belong to that key's
App ID group.

## Deterministic evidence

Shared application and rendered host tests run the Apple-first path for every
Gmail consent failure. They check cancellation, the Apple-specific copy, and the
relay address shown only as contact information. They also check that the
connected address comes from the Gmail grant. Convex tests prove an Apple identity
and a Google identity sharing a relay address remain separate Product Accounts.
Neither persists that address.

The [registration flow](google-registration.md#where-the-registration-flow-runs)'s
tests use a controlled Apple boundary in a synthetic native vault. They check Apple
cancellation and Gmail decline and connection, and confirm that no Google hint or
Google identity is derived from the Apple account. They also cover rejection of an
unlinked provider after registration, retention of the first contact address and
revoked-credential recovery. An interrupted registration restarts with Product
Sign-In. The hosted native storage suite's claim tests reject a Google token
presented as Apple. These are deterministic checks, not real Apple or Google
evidence.

The `registration-apple` Mock Mail Session drives the packaged journey: it signs
in with a synthetic Apple identity and a relay address, and declines the Gmail
session that follows. It then relaunches into pending setup, authorizes Gmail and
relaunches connected. Its native provider and runner rules match the
[Google registration sessions](google-registration.md#deterministic-evidence).

## Protected real qualification

Use signed hosts, a configured Convex development deployment, a test Apple ID and
the [protected Gmail test tenant](gmail-provider-test-tenant.md). Do not record
identity tokens, relay addresses or mailbox content in screenshots or artifacts.

On iPhone, iPad and Mac, register with Apple, choosing both shared and hidden
email. Confirm Gmail authorization is required before any connected status. Cancel
the Apple sheet, cancel and decline Gmail, then relaunch and finish. Register
Google first on a separate installation using the same email. Confirm the Product
Account IDs differ. Revoke the app in Apple ID settings and confirm restore offers
Sign in again with Apple without losing the Product Account. Record the results
separately from deterministic evidence. No real Apple sign-in pass is claimed
until this path has run.
