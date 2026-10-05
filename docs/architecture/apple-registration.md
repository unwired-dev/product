# Apple registration: architecture notes

Reviewer-only companion to [docs/apple-registration.md](../apple-registration.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Native verification and restore (replacement hosts)

The replacement hosts' `NativeAppleRegistrationProvider` bridge uses
`ASAuthorizationAppleIDProvider` with the email scope and a
fresh nonce for each session. It validates the returned identity token's issuer
(`https://appleid.apple.com`), audience (the host's bundle ID), subject, expiry and
nonce before calling `productAccount:connect`. Convex verifies the signature and
audience through Apple's OIDC provider.

Records written by
the Google slice have no provider field and are read as Google.

## Account deletion client binding

The deletion action accepts an optional `appleClientId` to select the host's
configured bundle ID before exchanging its single-use authorization code. The
selector grants no account access: the action still requires the authenticated
Product Account and a Trusted Device or Pending Device proof, and verifies the exchanged Apple token's
signature, issuer, expiry, subject and exact selected audience before revocation.
The same client is the client-secret subject and the exchange/revocation `client_id`.

The transient revocation-only token records its client ID so foreground retries
and scheduled recovery cannot select a different client's credentials. Legacy
token records without a client ID use `APPLE_BUNDLE_ID`. Revocation revalidates
the recorded client against the current configuration and fails closed if it was
removed. Successful revocation clears all revocation-token material before data deletion,
as required by [ADR 0021](../adr/0021-delete-product-accounts-immediately.md).
