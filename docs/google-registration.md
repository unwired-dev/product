# Google registration and Gmail consent

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/google-registration.md).

## Launch first-connection requirement

At the [power-user launch](product/power-user-launch.md#first-mailbox-after-product-sign-in),
Google Product Sign-In and device admission lead to a Mail Provider choice.
The sign-in mailbox may be suggested for Gmail, but the person can instead choose
iCloud Mail, Fastmail, manual IMAP/SMTP or Microsoft mail without granting Gmail
access. A Google Product identity without Gmail can therefore complete setup
with another Mail Provider. Microsoft mailbox authorization does not add a
Microsoft Product Sign-In.

Cancelling, declining or failing mailbox setup retains the Product Account and
offers retry or another provider, including after relaunch. Open an Inbox only
after the selected provider's connection is verified and setup is complete;
Gmail verification is required only for a Gmail connection. Adding another
mailbox offers the same provider choices and preserves existing connections on
failure or cancellation. These are launch requirements; the implementation and
evidence below describe the current Gmail path.

## Current Gmail implementation

[#596](https://github.com/unwired-dev/product/issues/596) adds the replacement
registration path to both native hosts. Until launch has read the saved registration,
the app shows Welcome's seal on its deep background with **Opening your mail…**, so an
installation with a Product Account never shows Welcome first
([#1070](https://github.com/unwired-dev/product/issues/1070)). The seal breathes unless
Reduce Motion is on, and the status line fades in after 0.6 seconds.
Signed out, the app opens on Welcome; its **Continue** leads to Sign In with
**Sign in with Apple** and **Sign in with Google**, and iPhone returns to Welcome with **Back**. A removed-device or deleted-account
notice opens Sign In directly with that notice. Product Sign-In creates or reconnects the
Product Account through Convex and then offers the first mailbox: the **Gmail** row
with the original account, **Choose another Google mailbox**, **Microsoft 365 and
Outlook** when configured for this build ([Microsoft mail](microsoft-mail.md)), or an
[IMAP mailbox](imap-mailboxes.md). Sign-in alone starts no mailbox authorization;
saved mailboxes that all need authorization again are authorized again right after
sign-in. Cancelled or declined Gmail consent and Google identities without
Gmail retain the Product Account, and both Gmail actions retry. Once a mailbox is
connected, the account page adds others with **Add another Gmail mailbox**; see
[Gmail mailboxes](gmail-inbox.md#gmail-mailboxes). A failed or cancelled addition
keeps every connected mailbox connected. Adding a mailbox does not link its Google
identity as another Product Sign-In; only [explicit linking](linked-sign-in.md) does.

Production builds open onboarding. Explicit `open-read-relaunch` and
`mail-unavailable` builds retain the synthetic Inbox preview. Once the mailbox is
connected and setup needs nothing more, the [Gmail Inbox](gmail-inbox.md) opens and
synchronizes it. A known network outage can open the last verified mailbox's
saved Inbox with a retry notice, while provider access stays closed until
verification succeeds. Rejected grants and unknown verification errors retain
resumable account setup. No synthetic message is presented as mail from the connected account.
[Apple registration](apple-registration.md) offers the other Product Sign-In and
the same mailbox choice.

## Native credentials and verification

The Gmail session requests `https://www.googleapis.com/auth/gmail.modify`. An identity token, a matching address or a cached receipt cannot
substitute for verified granted scope and Gmail mailbox access. Restoring a mailbox refreshes its credential and
rechecks Gmail access. Failed verification returns to pending setup.

JavaScript receives only account/connection status, opaque IDs and the mailbox
address. Refresh credentials and Gmail access tokens never enter JavaScript or
Convex. Convex receives the Product identity JWT and existing trusted-device proof
only. No mailbox connection metadata or provider credential is uploaded. The Product
identity JWT can contain Google profile claims, including the sign-in email.

## Where the registration flow runs

Both hosts share the TypeScript registration flow in `packages/mail-core`. It
owns restoring and resuming setup, Product Sign-In, switching and linking sign-ins,
mailbox authorization sequencing, sign-out and deletion sequencing, and the statuses
shown to the person. The hosts only wire native adapters. Every native result is
Schema-decoded and malformed replies fail closed against the shared Convex
contracts. Host-facing rejection codes and fixed texts are unchanged.

The native vault owns Google and Apple SDKs, device-only credentials and storage,
and backend calls that carry credentials. Tokens, credentials, installation
identifiers and provider subjects never enter TypeScript. Native stores every
issued device credential before returning its non-secret receipt. A reconnect
must open the retained Product Account. The flow also sequences
[Private Sync](private-product-sync.md#initialization-and-relaunch) initialization,
mailbox descriptor synchronization, device enrollment, Recovery Key recovery, key
rotation adoption and Device Revocation, and derives the Private Sync status it
shows. Native code keeps every key operation behind purpose-named steps.

Offline restore retains the Product Account and opens a previously verified
mailbox's saved Inbox when available. Without one, it reports mailbox setup as
unavailable. A record for another deployment or Google client is ignored.

Interruption after identity authorization can resume the same subject and installation ID. Pending setup offers
interactive sign-in again when the saved account cannot be verified or authorization
is interrupted. Cancelling Product Sign-In returns to the previous status without
an error; other native failures reject with their registration code and are logged
without credentials. A launch while the device is locked cannot read the saved
registration from Keychain: the bridge rejects with `locked`, both hosts show a
locked state instead of onboarding, and the shared store recovers quietly. Every
activation retries restore, as the Inbox does, including for an unlocked account.
An activation during a pending registration operation is retained until that
operation finishes. Unchanged restored state keeps setup and linking feedback;
changed verification results replace the previous status. Retry cannot replace
an existing Product identity with a different subject. Product Accounts remain
identified by verified issuer and subject, never by matching email. No existing
backend rows, Inbox files or Private Sync keys are reset or regenerated. A new
Product Account then [initializes Private Sync](private-product-sync.md). The device
that wins initialization presents the Recovery Key; another device of that account
[waits for approval](private-product-sync.md#approving-a-new-device) from a Trusted Device
or [unlocks with the Recovery Key](private-product-sync.md#recovering-with-the-recovery-key).

## Configure the hosts

Create a native OAuth client for the hosts' shared bundle ID `dev.unwired.mail`
in the protected Google project. Both hosts use Google's iOS/macOS SDK configuration,
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

[Push wakes](gmail-inbox.md#push-wake-routes) need three more settings. Set
`UNWIRED_GMAIL_PUBSUB_TOPIC` to the fully qualified Cloud Pub/Sub topic, such as
`projects/<project>/topics/gmail-push`, when generating each host. Grant
`gmail-api-push@system.gserviceaccount.com` permission to publish to it, and push
its subscription to `https://<deployment>.convex.site/gmail/push?token=<token>`
with the deployment's `GMAIL_PUSH_VERIFICATION_TOKEN`. The deployment's
`GMAIL_OAUTH_CLIENT_ID` must be the native client ID, because the relay verifies
each mailbox's identity token for that audience. The deployment also needs its
`GMAIL_ROUTING_*` keys and `APNS_*` credentials, with `APNS_TOPIC` set to
`dev.unwired.mail`. Without a topic, a host registers no route and synchronizes on
its schedule alone.
Do not commit configured deployment values or credentials. App Check enforcement,
App Store disclosures and distribution entitlements remain protected release
qualifications; Google's audience and verification follow
[production authorization](#production-authorization).

On Mac, real sign-in requires development signing and a matching provisioning
profile even in Debug. An ad-hoc build can show onboarding but Google's SDK cannot
store its credential. Its `com.google.GIDSignIn` error code `-2` identifies this
Keychain failure. The native adapter retains the SDK error for the private OS log;
JavaScript still receives only the stable registration failure code.

## Production authorization

[#668](https://github.com/unwired-dev/product/issues/668) requires that people outside
the test-user list can register with Google, or with Apple and then Gmail, and
authorize Gmail in the released app. **Status: not established.** No production
consent configuration, Google verification or production-host run is recorded.
Google requirements below were checked on 2026-10-25.

### What the hosts request

| Request               | Scopes                                                                                                | Google classification |
| --------------------- | ----------------------------------------------------------------------------------------------------- | --------------------- |
| Product Sign-In       | `email` and `profile`, which GoogleSignIn 10.0.0 adds to every sign-in, and the OpenID ID token       | Non-sensitive         |
| Gmail mailbox consent | The same sign-in plus `https://www.googleapis.com/auth/gmail.modify` (`RegistrationStore.gmailScope`) | Restricted            |

Google's consent screen lists these as `openid`, `.../auth/userinfo.email`,
`.../auth/userinfo.profile` and `.../auth/gmail.modify`. Configure exactly these
four scopes. The SDK sends `include_granted_scopes`, so a grant can include scopes
given to the same client earlier. Mailbox verification also accepts
`https://mail.google.com/` in such a grant, but the hosts never request it.

`gmail.modify` is the narrowest single scope for the shipped behavior: reading
metadata and bodies, history synchronization, archive, label, read state and
Trash changes, sending, and `users/me/watch` and `stop`. Every narrower scope that
reads bodies (`gmail.readonly`) or metadata (`gmail.metadata`) is restricted as
well, and neither allows changing labels or sending. Splitting the grant would
add scopes without avoiding restricted-scope verification.

Configuration in the repository:

- **OAuth client:** one native iOS client for bundle ID `dev.unwired.mail`, used by
  iPhone, iPad and Mac through `UNWIRED_GOOGLE_CLIENT_ID`. Its redirect is the
  reversed client-ID URL scheme. There is no web client, client secret or web redirect.
  Convex accepts several Product Sign-In audiences (`GOOGLE_PRODUCT_CLIENT_IDS`), but
  the push relay verifies mailbox identity tokens for one (`GMAIL_OAUTH_CLIENT_ID`).
  Separate platform clients would therefore need a relay change before push wakes
  work on every host.
- **Cloud Pub/Sub:** the Gmail push topic and its subscription to the Convex relay,
  as configured above.
- **Not in the repository:** the production project's audience and publishing
  status, app name, logo, support and developer contacts, home page, privacy policy,
  authorized domains and verification state. The owner records them, without
  identifiers or credentials, when production is configured.

### Google's requirements for these scopes

Sources: [restricted-scope verification](https://developers.google.com/identity/protocols/oauth2/production-readiness/restricted-scope-verification),
[Gmail API scopes](https://developers.google.com/workspace/gmail/api/auth/scopes),
[OAuth app audience](https://support.google.com/cloud/answer/15549945).

- **Audience.** The protected test tenant's internal audience admits only its own
  organization. An external app in **Testing** admits at most 100 listed test users,
  and their grants and refresh tokens expire seven days after consent because
  Gmail is not a basic-profile scope. An unverified app **In production** shows the
  unverified-app warning and admits 100 new users over the project's lifetime.
  The public release therefore needs an external audience, **In production**, with
  restricted-scope verification complete.
- **Exceptions.** None of Google's exceptions applies to the public release:
  personal use, development or testing, service-owned data, internal use, or
  domain-wide installation.
- **Verification.** Brand verification, domain ownership verified in Google Search
  Console, a public home page, and a privacy policy on that domain meeting the
  Limited Use requirements. Also an unlisted YouTube demo video showing how a person
  starts and grants Gmail access, and a justification of why narrower scopes are
  insufficient (above).
- **Security assessment.** Google requires one when restricted-scope data is stored
  on servers or transmitted through them. Google's pages make no exception for
  device-local credentials or end-to-end encryption. The current hosts send Gmail
  data through the product backend in two ways:
  - **Push wakes:** Pub/Sub delivers each Gmail notification, with its mailbox
    address and history ID, to the Convex relay. The relay keeps keyed address
    digests and history IDs to match wakes to routes.
  - **Private Sync Drafts:** reply and forward Drafts hold the answered message's
    quoted text, and forwards carry its attachments as Draft Assets. Both are
    stored end-to-end encrypted in Convex.

  Plan for a security assessment, renewed with reverification at least every 12
  months. Avoiding it requires either Google's written confirmation that these
  flows are out of scope, or removing them: polling-only Gmail freshness, and no
  Gmail-derived content in Private Sync. The planned
  [provider-hosted Drafts](drafts.md#provider-hosted-draft-launch-plan) would remove
  the second flow.

### Google user data disclosure

The privacy policy states these facts for Google's review. Revise them with any
change to the flows above.

- **Access:** the Google account's name, email address and profile picture for
  Product Sign-In; Gmail messages, labels and sending through `gmail.modify` for
  each mailbox the person connects.
- **Use:** only to provide the mail features the person uses. Summaries,
  translation, rewrites and categorization run on the person's device. Google user
  data is not used for advertising and is not used to develop, improve or train
  generalized AI or machine-learning models.
- **Storage:** Gmail tokens stay in the device's Keychain. Mail is cached encrypted on
  the device. The backend receives the Google identity token for Product Sign-In and
  for registering push wakes. It stores the sign-in's issuer and subject, keyed
  digests of mailbox addresses and identities, Gmail history IDs, and end-to-end
  encrypted Private Sync data, including Drafts, that it cannot read.
- **Sharing:** Google user data is not sold or shared, except as needed to deliver
  push wakes through Google Cloud Pub/Sub and Apple Push Notification service.
  Opt-in [error reports](telemetry.md) exclude message content.
- **Limited Use:** the policy contains Google's required statement that the app's
  use and transfer of information received from Google APIs adheres to the
  [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy),
  including the Limited Use requirements.

### Remaining owner actions

1. Decide the security-assessment route above.
2. Configure the production project: external audience, the four scopes above, app
   name and logo, support and developer contacts, and the verified domain's home page
   and privacy policy, including the disclosure above.
3. Submit brand and restricted-scope verification with the scope justification and
   demo video, and complete any security assessment.
4. After approval, on iPhone, iPad and Mac with a dedicated account outside the
   test-user list, verify Google and Apple-then-Gmail registration, Gmail consent,
   token refresh after relaunch, and recovery after revoking the grant in the Google
   account. Keep credentials and mailbox content out of the evidence.
5. Record the configuration and verification status here without identifiers. Until
   then, intended users stay blocked and #668 stays open.

## Deterministic evidence

Shared application and rendered host tests construct Registration over the
synthetic native vault (`packages/mail-core/src/testing/registration-vault.ts`), so
they run the real registration flow and Product Sync. The registration Mock Mail
Session scenarios are presets of that vault
(`packages/mail-core/src/testing/registration-scenarios.ts`). These tests exercise
consent separation, errors, retry, adding, reauthorizing and removing mailboxes, and
remounting. The flow's own tests run it over the same vault directly: consent
failures, interrupted Google and Apple registration, offline restore, another
client's record, linking and its refusals, sign-out and deletion sequencing,
revocation, Convex reply decoding and the fixed rejection codes. Convex tests exercise public account operations with authenticated
test identities and prove same-address Apple and Google isolation; `convex-test`
does not exercise the deployment's JWT gateway.

The hosted native storage suite exercises real Keychain persistence of an
interrupted sign-in, connect receipt validation, credential attachment to
credentialed calls, a projection free of secrets and provider subjects, Gmail
verification failure, several mailbox connections, wrong-subject rejection and
preservation of existing encrypted Inbox bytes. Its tests reach registration states
through the vault operations in the flow's order. Its
Google and backend boundaries are controlled synthetic providers. The nonce,
issuer, audience and expiry checks run there too. These checks are deterministic
native application integration evidence, not real OAuth evidence.

External Mock Mail Sessions also accept `registration-cancelled`,
`registration-declined`, `registration-no-gmail`, `registration-interrupted`,
the Apple-first [`registration-apple`](apple-registration.md#deterministic-evidence),
[`registration-link`](linked-sign-in.md#deterministic-evidence), and the Private Sync
[`registration-enrollment` and `registration-recovery`](private-product-sync.md#deterministic-evidence).
In an explicitly selected build, the real native vault asks a relay compiled only
with `UNWIRED_REGISTRATION_MOCK`, and the synthetic TypeScript layers in
`packages/mail-core/src/testing/` answer as Google, Apple, Microsoft and Convex
would. Each accepts only its fixed scenario and has no network or real credential
inputs. Their bundles add only those synthetic layers to production JavaScript; the
bundle checks expect them in every selected registration bundle. Both native UI probes retain the original Inbox journey
and add registration, relaunch into pending setup, alternate mailbox authorization
and connected relaunch. The existing disposable app/simulator ownership and
cleanup rules apply; Mac cleanup removes the run's registration Keychain record
as well as its Inbox key.

```sh
mise exec -- pnpm exec turbo run lint format check-types test --filter=// \
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
issuer cannot read this account's devices or Private Sync data.

At the real callback boundary, dismiss the session, deliver an old/duplicate
callback, and deliver a callback with the wrong state. They must not complete a
new session or replace retained credentials. Verify token refresh after process
relaunch, configured audience rejection in Convex, device-only Keychain policy,
physical lock/unlock behavior and signed Mac storage. Record target, SDK/toolchain,
non-secret scenario result and evidence date separately from deterministic tests.
No real OAuth pass is claimed until this protected path has actually run.

Launch qualification must additionally exercise Google-first registration with
each non-Gmail provider and no Gmail grant, including a Google identity without
Gmail, cancellation, choosing a different provider, retry and connected relaunch.
Track that evidence in [#855](https://github.com/unwired-dev/product/issues/855);
the Gmail scenarios above do not qualify those paths.
