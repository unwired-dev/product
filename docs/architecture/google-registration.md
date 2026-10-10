# Google registration: architecture notes

Reviewer-only companion to [docs/google-registration.md](../google-registration.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Native credentials and verification

GoogleSignIn 10.0.0 supplies the system authorization session, PKCE, OAuth state
and callback handling, and token refresh. Each interactive session also supplies
a fresh nonce. The native adapter validates the returned identity's issuer,
audience, subject, expiry and nonce. Only tokens returned directly by the SDK's
Google token exchange are accepted at that boundary. Convex independently verifies
the Product Sign-In JWT signature and configured audience through Google's OIDC
provider. Deterministic claim tests do not prove Google's live signing-key behavior.

The application checks the token response's actual granted scopes through
`GIDGoogleUser.grantedScopes` and calls Gmail `users/me/profile` with the resulting
access token.

Identity and mailbox users are archived independently in a native Keychain record
using `WhenUnlockedThisDeviceOnly`, no synchronization and the Mac Data Protection
Keychain. The SDK's transient sign-in cache is cleared after each interactive
session. Its default credential cache uses `AfterFirstUnlockThisDeviceOnly`.

The record is bound to its native client ID and Convex deployment.

Interruption
after identity authorization persists the credential before the backend call;
retry resumes the same subject and stable installation ID.

## TypeScript flow and native vault

The registration flow runs in TypeScript, in
`packages/mail-core/src/registration-flow.ts`, over a minimal native vault. Both
hosts' `registration.ts` only wire the vault's native methods into
`createRegistrationFlow`, whose Effect programs `createRegistration` composes in the shared
store before its single host-facing run. TypeScript decides every step: restoring, signing in, switching to a Linked
Sign-In, linking, verifying and adding mailboxes, recording why setup ended, and the
order of sign-out and deletion. It builds every status value and Schema-decodes
every native result, failing closed on anything malformed.

The native vault keeps what must stay on the device and performs one purpose-named
operation per call:

- **The saved registration** in the Keychain. TypeScript reads a projection with
  no credential, token, device identifier or provider subject. Connections appear
  only by their opaque IDs, with this process's verification state. A record for
  another deployment or Google client is never projected.
- **Provider sign-ins.** Google Sign-In, Gmail authorization and Sign in with Apple
  report only whether the identity is the saved account and which scopes Gmail
  granted. The latest identity stays native for the next step to present.
- **Connecting.** `productAccount:connect` issues the device credential, so native
  sends it, validates and stores the receipt before returning, and refuses a
  reconnect that reaches another Product Account.
- **Credentialed calls.** For every other Convex call, TypeScript names the function
  or HTTP route and its non-secret arguments, and which credentials to attach: the
  latest Product Sign-In's token, this device's Trusted or Pending Device proof, its
  installation identifier, or the Apple authorization code. Native attaches them and
  returns the HTTP status and body; TypeScript decodes the reply and maps Convex
  codes. Native refuses `productAccount:connect` through this path.
- **Product Sync, enrollment, recovery and revocation** stay native as temporary
  purpose-named operations until
  [#757](https://github.com/unwired-dev/product/issues/757) and
  [#758](https://github.com/unwired-dev/product/issues/758) move them. Until then they
  keep their own Swift Convex transport.

The registration rejection codes and texts hosts receive are unchanged. Transient
transport failures reach the flow as `offline`, which lets a restore open the
last verified mailbox's saved Inbox; hosts still see them as `unavailable`.

The TypeScript response schemas are checked against the types inferred by the
`packages/contracts` Convex validators. Native void steps resolve with null and
are decoded as null before the flow continues. The retained Swift Convex helper
serves only purpose-specific connect and the native work awaiting #757/#758; this
transitional transport reuse was approved by the #756 decision panel (3–0).
