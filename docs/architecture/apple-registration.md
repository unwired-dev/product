# Apple registration: architecture notes

Reviewer-only companion to [docs/apple-registration.md](../apple-registration.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Native verification and restore

The native adapter uses `ASAuthorizationAppleIDProvider` with the email scope and a
fresh nonce for each session. It validates the returned identity token's issuer
(`https://appleid.apple.com`), audience (the host's bundle ID), subject, expiry and
nonce before calling `productAccount:connect`. Convex verifies the signature and
audience through Apple's OIDC provider.

Records written by
the Google slice have no provider field and are read as Google.
