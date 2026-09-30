# Google registration and Gmail consent

[#596](https://github.com/unwired-dev/product/issues/596) adds the replacement
registration path to both native hosts. Product Sign-In creates or reconnects the
Product Account through Convex before a separate Gmail authorization session.
Cancelled or declined Gmail consent and Google identities without Gmail retain
the Product Account. Retry can use the original account or another Google mailbox.
Adding that mailbox does not link its Google identity as another Product Sign-In.

Production builds open onboarding. Explicit `open-read-relaunch` and
`mail-unavailable` builds retain the synthetic Inbox preview. A connected Gmail
status confirms authorization only; mailbox synchronization belongs to the later
Gmail slices. No synthetic message is presented as mail from the connected account.
Apple's existing backend provider and prototype checks remain available; Apple
registration in the replacement is a separate slice.

## Native credentials and verification

GoogleSignIn 10.0.0 supplies the system authorization session, PKCE, OAuth state
and callback handling, and token refresh. Each interactive session also supplies
a fresh nonce. The native adapter validates the returned identity's issuer,
audience, subject, expiry and nonce. Only tokens returned directly by the SDK's
Google token exchange are accepted at that boundary. Convex independently verifies
the Product Sign-In JWT signature and configured audience through Google's OIDC
provider. Deterministic claim tests do not prove Google's live signing-key behavior.

The Gmail session requests `https://www.googleapis.com/auth/gmail.modify`. The
application checks the token response's actual granted scopes through
`GIDGoogleUser.grantedScopes` and calls Gmail `users/me/profile` with the resulting
access token. An identity token, a matching address or a cached receipt cannot
substitute for either check. Restoring a mailbox refreshes its credential and
rechecks Gmail access. Failed verification returns to pending setup.

Identity and mailbox users are archived independently in a native Keychain record
using `WhenUnlockedThisDeviceOnly`, no synchronization and the Mac Data Protection
Keychain. The SDK's transient sign-in cache is cleared after each interactive
session. Its default credential cache uses `AfterFirstUnlockThisDeviceOnly`.
JavaScript receives only account/connection status, opaque IDs and the mailbox
address. Refresh credentials and Gmail access tokens never enter JavaScript or
Convex. Convex receives the Product identity JWT and existing trusted-device proof
only. No mailbox connection metadata or provider credential is uploaded. The Product
identity JWT can contain Google profile claims, including the sign-in email.

The record is bound to its native client ID and Convex deployment. Interruption
after identity authorization persists the credential before the backend call;
retry resumes the same subject and stable installation ID. Pending setup offers
interactive sign-in again when refresh or authorization is interrupted. Retry cannot replace
an existing Product identity with a different subject. Product Accounts remain
identified by verified issuer and subject, never by matching email. No existing
backend rows, Inbox files or Product Sync keys are reset or regenerated. This
slice does not initialize or recover Product Sync key material.

## Configure the hosts

Create separate native OAuth clients for the exact iPhone/iPad and Mac bundle IDs
in the protected Google project. Both use Google's iOS/macOS SDK configuration,
including the reversed client-ID URL scheme. Enable Gmail API and review the
consent screen's restricted scope and test-user configuration. Do not provide a
web client secret or send provider refresh credentials to Convex.

Set `UNWIRED_GOOGLE_CLIENT_ID` and `UNWIRED_CONVEX_URL` when generating each host.
They are public configuration, embedded in that host's Info.plist. Mobile's config
plugin also installs GoogleSignIn and adds the SDK URL handler. Mac's generator
adds its URL event handler, native bridge and plist entries. Set
`GOOGLE_PRODUCT_CLIENT_IDS` on the Convex deployment to the comma-separated native
client IDs, then deploy the auth configuration. An empty list adds no Google
provider and leaves the existing Apple provider intact. Every Google audience
must be explicit; there is no audience-free JWT provider.

```sh
UNWIRED_GOOGLE_CLIENT_ID='<native client ID>' \
UNWIRED_CONVEX_URL='https://<deployment>.convex.cloud' \
mise exec -- pnpm --filter @private-email/mobile native:generate --no-install
cd apps/mobile/ios
pod install
```

Use the corresponding environment values with
`pnpm --filter @private-email/macos native:build Testing` under the
[Mac signing prerequisites](macos-client.md#build-and-run).
Do not commit configured deployment values or credentials. App Check enforcement,
restricted-scope verification, App Store disclosures and distribution entitlements
remain protected release qualifications.

## Deterministic evidence

Shared application and rendered host tests use fixed synthetic registration
sessions. They exercise consent separation, errors, retry, reselection and
remounting. Convex tests exercise public account operations with authenticated
test identities and prove same-address Apple and Google isolation; `convex-test`
does not exercise the deployment's JWT gateway.

The hosted native storage suite exercises real Keychain persistence, interrupted
registration, consent failures, Gmail verification failure, account reselection,
wrong-subject rejection and preservation of existing encrypted Inbox bytes. Its
Google and backend boundaries are controlled synthetic providers. The nonce,
issuer, audience and expiry checks run there too. These checks are deterministic
native application integration evidence, not real OAuth evidence.

External Mock Mail Sessions also accept `registration-cancelled`,
`registration-declined`, `registration-no-gmail` and `registration-interrupted`.
Their native provider is compiled only with `UNWIRED_REGISTRATION_MOCK` in an
explicitly selected build, accepts only its fixed scenario, and has no network or
real credential inputs. Both native UI probes retain the original Inbox journey
and add registration, relaunch into pending setup, alternate mailbox authorization
and connected relaunch. The existing disposable app/simulator ownership and
cleanup rules apply; Mac cleanup removes the run's registration Keychain record
as well as its Inbox key.

```sh
mise exec -- pnpm exec turbo run lint format check-types test \
  --filter=@private-email/mobile... --filter=@private-email/macos... \
  --filter=@private-email/convex...
mise exec -- pnpm test:native-runner
mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

For packaged onboarding, substitute `registration-declined` for
`open-read-relaunch` in the [native Mock Mail Session commands](mock-mail-sessions.md).
Run normal and selected JavaScript exports and their matching bundle checks.
Version-27 native and protected checks remain required before release when unavailable.

## Protected real OAuth qualification

Use only the [protected Gmail test tenant](gmail-provider-test-tenant.md), approved
native client IDs, a configured Convex development deployment and signed hosts.
Never put these credentials in a Mock Mail Session. Follow the tenant's access and
account-isolation requirements. Do not record authorization URLs, tokens or
mailbox content in screenshots, logs or test artifacts.

On iPhone, iPad and Mac, verify identity-only account creation followed by actual
Gmail consent. Cancel, decline the Gmail scope, and select a Google identity
without Gmail; confirm the Product Account survives and no Inbox appears. Relaunch
and complete consent, including selection of another protected Google mailbox.
Confirm the Product Account ID stays fixed. Expire/revoke the mailbox grant and
confirm restore does not report a connection. Reauthenticate the original Product
identity independently. Verify an account with the same email under another
issuer cannot read this account's devices or encrypted Product Sync data.

At the real callback boundary, dismiss the session, deliver an old/duplicate
callback, and deliver a callback with the wrong state. They must not complete a
new session or replace retained credentials. Verify token refresh after process
relaunch, configured audience rejection in Convex, device-only Keychain policy,
physical lock/unlock behavior and signed Mac storage. Record target, SDK/toolchain,
non-secret scenario result and evidence date separately from deterministic tests.
No real OAuth pass is claimed until this protected path has actually run.
