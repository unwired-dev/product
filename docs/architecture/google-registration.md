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
