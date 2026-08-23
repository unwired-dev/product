# Qualify AppAuth without moving Gmail credential ownership

## Status

Accepted for protected qualification; production migration deferred.

## Context

The Apple app's Gmail authorization flow already has a narrow `GmailOAuthAuthorizing` boundary.
Product code, rather than the browser authorization library, owns Mailbox Connection identity,
scope verification, token persistence, refresh recovery, disconnect, revocation handling, and
trusted-device behavior. Any candidate must preserve that ownership and support multiple Gmail
Mailbox Connections without a global current-user object.

AppAuth-iOS 2.1.0 is Apache-2.0 licensed and resolves at commit
`a7caeda164dc5108bf4649472b28a5af65dc6f33`. Its Swift package contains AppAuth and AppAuthCore
privacy manifests declaring no tracking, collected data, or required-reason API access. AppAuth's
authorization request generates secure state, nonce, and S256 PKCE values and its Apple external
user agents use `ASWebAuthenticationSession`.

## Decision

Pin AppAuth 2.1.0 exactly and keep its adapter behind `GmailOAuthAuthorizing`. The candidate owns
only the transient system-browser request, callback validation, and authorization-code exchange.
Every pending request has its own AppAuth session and continuation, so cancellation and callbacks
cannot consume another Mailbox Connection's result. AppAuth authorization state is not persisted.

Keep the existing product-owned connection pipeline unchanged. It verifies the refreshed Google
subject, Gmail profile identity, and accepted Gmail scope before saving credentials. It persists
access and refresh tokens in connection-scoped Keychain items using
`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, excludes identity tokens from persistence, and
keeps all credentials out of Product Sync and backend-readable state. Refresh responses now retain
a rotated refresh token when Google returns one and preserve the current token when Google omits
one.

Ordinary builds continue using `GoogleGmailOAuthService`. Debug and test builds select AppAuth only
when `UNWIRED_GMAIL_OAUTH_IMPLEMENTATION=appauth`; Release builds ignore that environment value.
This permits the protected Provider Compatibility Run without silently migrating production.

Do not add GTMAppAuth. The spike does not adopt Google's REST client, and AppAuth's token response
is immediately converted to the existing product token model. Another Google-specific state layer
would add no responsibility that this qualification needs.

## Consequences

- AppAuth is accepted as an internal-only candidate, not as the shipping implementation.
- Multiple requests have no global current-user or shared-token state.
- Product credential, identity, scope, recovery, and trusted-device behavior does not move into a
  third-party cache.
- AppAuth's Apache-2.0 notice appears in the app's open-source acknowledgements.
- A protected provider run remains required because system-browser behavior during device lock,
  Google consent, grant revocation, and refresh rotation cannot be proved by local fixtures.

## Migration and removal

After the protected run in `docs/qualification/appauth-gmail-oauth.md` passes, propose production
selection in a separate reviewed change. That change must preserve the protocol boundary and
product verifier, run the current-head Apple matrix, and remove the environment selector. After a
release soak, remove `GoogleGmailOAuthService`, its handwritten request, PKCE, callback, and token
exchange helpers, plus their superseded tests; do not retain it as a fallback.

If the protected run fails, remove AppAuth from the Xcode project and package resolution, delete
`AppAuthGmailOAuthService.swift` and its tests, remove the acknowledgement and qualification docs,
and retain the current implementation. The candidate therefore remains mechanically removable.
