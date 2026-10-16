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
`createRegistration`. The shared store builds `createRegistrationFlow` from that
vault and composes its Effect programs before its single host-facing run.
TypeScript decides every step: restoring, signing in, switching to a Linked
Sign-In, linking, verifying and adding mailboxes, recording why setup ended, and the
order of sign-out and deletion. It builds every status value and Schema-decodes
every native result, failing closed on anything malformed.

The native vault keeps what must stay on the device and performs one purpose-named
operation per call:

- **The saved registration** in the Keychain. TypeScript reads a projection with
  no credential, token, device identifier or provider subject. Connections appear
  only by their opaque IDs, with this process's verification state. A record for
  another deployment or Google client is never projected.
- **Provider sign-ins.** Google Sign-In, Sign in with Apple, and independent Gmail
  or Microsoft mailbox authorization report only whether the identity is the saved
  account and the granted mailbox scopes. After device admission, first use shows
  provider choice rather than automatically requesting Gmail consent. The latest identity stays native for the next step to present.
- **Connecting.** `productAccount:connect` issues the device credential, so native
  sends it, validates and stores the receipt before returning, and refuses a
  reconnect that reaches another Product Account.
- **Credentialed calls.** For every other Convex call, TypeScript names the function
  or HTTP route and its non-secret arguments, and which credentials to attach: the
  latest Product Sign-In's token, this device's Trusted or Pending Device proof, its
  installation identifier, or the Apple authorization code. Native attaches them and
  returns the HTTP status and body; TypeScript decodes the reply and maps Convex
  codes. Native refuses `productAccount:connect` through this path.
- **Private Sync initialization and synchronization** run in
  `packages/mail-core/src/product-sync.ts`. The flow derives status from a
  non-secret projection, selects descriptor reads and CAS writes, and calls native
  operations to create/store keys and seal/open records. Credentialed calls attach
  the process's verified Product Sign-In session when requested.
- **Enrollment, recovery, rotation adoption, device-list refresh and revocation**
  run as Effect programs in `packages/mail-core/src/product-sync-devices.ts`.
  TypeScript holds the process's device lists and selects ordinary credentialed
  calls. Purpose-named native steps keep key operations, recovery-proof calls,
  admission receipt storage and durable removal material. Native Draft sync
  retains its list/put/get transport and asks the TypeScript registration flow
  to adopt after an old-epoch write refusal; mailbox descriptor coordination
  uses the TypeScript call primitive.

The registration rejection codes and texts hosts receive are unchanged. Transient
transport failures reach the flow as `offline`, which lets a restore open the
last verified mailbox's saved Inbox; hosts still see them as `unavailable`.

The TypeScript response schemas are checked against the types inferred by the
`packages/contracts` Convex validators. Native void steps resolve with null and
are decoded as null before the flow continues. The retained Swift Convex helper
serves purpose-specific credential/proof calls and native Draft sync; this
transitional transport reuse was approved by the #756 decision panel (3–0).
