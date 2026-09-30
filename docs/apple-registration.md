# Apple registration and Gmail authorization

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
a Linked Sign-In. Its Google identity never reaches Convex. Explicit linking is
out of scope. On a device with a committed Product Account, sign-in through the
other provider is rejected rather than switching or merging accounts.

Apple may return a private relay address. The native adapter keeps it in the
device-only registration record and shows it as the account's contact email. It
is display and contact information only. It is never used as a Google account
hint, never selects or verifies a mailbox and is not stored by Convex. The Gmail
session after Apple sign-in starts without a Google account hint.

## Native verification and restore

The native adapter uses `ASAuthorizationAppleIDProvider` with the email scope and a
fresh nonce for each session. It validates the returned identity token's issuer
(`https://appleid.apple.com`), audience (the host's bundle ID), subject, expiry and
nonce before calling `productAccount:connect`. Convex verifies the signature and
audience through Apple's OIDC provider.

Native Sign in with Apple cannot renew an identity token without user interaction.
Restore and Gmail authorization therefore check the Apple credential state for
the saved subject instead of reconnecting to Convex. A revoked, missing or
unverifiable credential keeps the Product Account and mailbox-setup record. The
host then reports that the account could not be verified and offers Sign in again
with Apple. Backend operations that need a current Apple token belong to later
slices. They must reauthenticate interactively or add a server-side token exchange.

Cancelling the Apple sheet returns to the previous status without an error.
If Convex does not confirm a new Apple registration, the record keeps the
subject and installation ID. Restore reports Product Sign-In as the remaining
step, and signing in with the same Apple ID resumes it. A record that never received a Product Account may
be replaced by another Sign-In Provider. Once registration completes, Gmail
cancellation, decline, missing Gmail and interruption keep it. The host reports
the Gmail step as remaining, exactly as for Google registration. Records written by
the Google slice have no provider field and are read as Google.

## Configure the hosts

Enable Sign in with Apple for the iPhone/iPad App ID `dev.unwired.mail.preview`
and the Mac App ID `dev.unwired.mail.macos.preview`. The Expo config
declares the entitlement for generated iOS projects. The Mac entitlements file declares
it for signed builds. Every development profile used to sign the Mac `Testing` build
must include the capability. Ad-hoc Mac builds compile, but the system rejects
Apple authorization without the entitlement; the host logs that failure without
credentials.

Native Apple authorization uses the system sheet and has no redirect URL or URL
scheme. Google still needs its reversed client-ID URL scheme and configured
`UNWIRED_GOOGLE_CLIENT_ID` for the Gmail step. Apple-first registration therefore
needs the same [Google host configuration](google-registration.md#configure-the-hosts).

Set `APPLE_PRODUCT_CLIENT_IDS` on the Convex deployment to the comma-separated host
bundle IDs, then deploy the auth configuration. These are public token audiences.
`APPLE_BUNDLE_ID` continues to name the Swift prototype's audience.

```sh
npx convex env set APPLE_PRODUCT_CLIENT_IDS \
  'dev.unwired.mail.preview,dev.unwired.mail.macos.preview'
```

## Deterministic evidence

Shared application and rendered host tests run the Apple-first path for every
Gmail consent failure. They check cancellation, the Apple-specific copy, and the
relay address shown only as contact information. They also check that the
connected address comes from the Gmail grant. Convex tests prove an Apple identity
and a Google identity sharing a relay address remain separate Product Accounts.
Neither persists that address.

The hosted native storage suite uses a controlled Apple boundary with real
Keychain persistence. It checks Apple cancellation and Gmail decline and
connection. It confirms that no Google hint or Google identity is derived from
the Apple account. It also covers rejection of the other provider after
registration, retention of the first contact address and revoked-credential
recovery. An interrupted registration restarts with Product Sign-In. Claim tests
reject a Google token presented as Apple. These are deterministic native
application checks, not real Apple or Google evidence.

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
