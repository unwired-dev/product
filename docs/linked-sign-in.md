# Linked Google and Apple sign-in

Setup, coding rules, validation and observable requirements remain in this file.
The review agent owns the separate [architecture companion](architecture/linked-sign-in.md).

[#598](https://github.com/unwired-dev/product/issues/598) lets a person add the
other Sign-In Provider to an existing Product Account. After linking, either
[Apple](apple-registration.md) or [Google](google-registration.md) opens the same
Product Account on iPhone, iPad and Mac. It follows
[ADR 0061](adr/0061-separate-product-identity-from-registration-mailbox-authorization.md):
linking is explicit and verifies both identities. It never merges Product Accounts.

## Account settings and sign-in

Once a Product Account exists, the registration screen shows **Sign-in methods**.
With one provider it says only that provider opens the account and offers
**Link Google sign-in** or **Link Apple sign-in**. The copy says linking adds a
way to sign in and does not connect a mailbox. After linking it names both
providers. The copy also explains the session order: linking Apple from a Google
account opens Google first to verify the existing sign-in, then Apple to add the
other identity. Linking does not change the connected Gmail mailbox.

Signing in with a linked provider on another installation opens the same Product
Account through the ordinary **Sign in with Apple** or **Sign in with Google**
entry point. The account lists the other provider. On a device whose saved sign-in
cannot be verified, the host also offers **Sign in with Google instead** or
**Sign in with Apple instead**. One case is an Apple ID revoked in settings. The
device keeps its installation ID, Trusted Device and mailbox records. A connected
mailbox is rechecked with Gmail rather than sent through consent again. The host
offers the other provider even before this device has seen the link. The device
asks Convex rather than trusting its cached list, which may predate a link made
elsewhere. Convex rejects a provider identity that is not linked to the device's
Product Account. It creates no new account, and the device record is unchanged.

## Identity boundaries

A link requires recent verification of both identities in one interactive session:

The current identity must match the saved one. Verify both identities with fresh
interactive authentication, without using a mailbox or relay address as an
account hint. Each identity token must have been issued within the last five minutes, and the
link request expires after five minutes. Expired verification requires a fresh
interactive attempt immediately; there is no waiting period.

The native host sends each identity token only as the Authorization bearer header
on `POST /sign-in-links/request` and `POST /sign-in-links/complete`, using the
configured deployment's `.convex.site` HTTP actions. Convex verifies the exact
bearer token's signature, issuer and audience before the handler runs. The handler
decodes its `iat` claim, binds its issuer and subject to the verified identity, and
checks the five-minute limit with five seconds of future clock skew. Reserved OIDC
claims such as `iat` are absent from `getUserIdentity()` and cannot supply this
check. The ownership mutations are internal, so callers cannot bypass the HTTP
freshness check. Deploy the backend and rebuild the native hosts together; the
former public `signInLinks:request` and `signInLinks:complete` mutations are retired.

Each verified issuer and subject has exactly one owner. Completion is rejected
when the identity created another Product Account, is linked elsewhere, or
belongs to a deleted account. A matching email address is never consulted. A
Product Account holds at most one identity per provider.

The added Gmail mailbox is a Mailbox Connection. Its Google identity never reaches
Convex and never becomes a Linked Sign-In. Selecting the same Google account in
the link session is an explicit choice and still requires its own verification.

## Interruption and concurrency

The Product Account, its linked identities and the device record stay unchanged
until completion commits. Cancelling either session, a stale token, an
expired ticket or a network failure leaves the Product Account and its sign-ins
unchanged. The host shows a link-specific
message. Retrying starts a new request. If completion committed but the response
was lost, retrying the consumed ticket returns the committed link. A later
request also reports the provider as already linked.

Racing link attempts cannot both commit.
A newer ticket invalidates an older one for the same provider. An identity
claimed concurrently by registration or another account commits only once.

If the presented identity
does not resolve to that account, sign-in is rejected. It creates no account and reveals no other account.

## Deletion and remaining work

Deleting a Product Account tombstones every Linked Sign-In with it. A linked
identity can then neither reopen the account nor create a new one. A deletion
request made through a Linked Sign-In is keyed by the account's original identity.
[Deletion](account-removal.md) needs a recent interactive Product Sign-In that
opens the account:

- **Apple sign-in:** required whenever Sign in with Apple opens the account,
  whether Apple created it or was linked to it. Convex exchanges and revokes the
  Apple authorization with the bundle ID that issued it, including replacement-host
  [client IDs](apple-registration.md#configure-the-hosts).
- **Google sign-in:** deletes an account that only Google opens. Google
  authorization already given is not revoked.

Unlinking, replacing a linked identity and merging existing Product Accounts are
out of scope. Linking needs no new host or deployment configuration beyond
[Apple](apple-registration.md#configure-the-hosts) and
[Google](google-registration.md#configure-the-hosts) registration.

## Deterministic evidence

Convex integration tests exercise both `/sign-in-links` HTTP actions and
`productAccount:connect` with authenticated test identities. The verified identity
omits reserved token timestamps; freshness is checked from a synthetic bearer
token. Missing, stale, future, malformed and identity-mismatched claims fail closed
before any link state changes, and malformed request bodies are rejected. They cover
alternate sign-in from a second installation and a same-email identity that stays
separate. They also cover identities owned by other accounts, superseded tickets
and stale tokens on either side. Expired, wrong-provider and wrong-device tickets
are rejected, and a lost completion response can be retried. Deletion tombstones
both identities. `convex-test` does not exercise the deployment's JWT gateway.

Shared application and rendered host tests cover linking from account settings,
persistence across relaunch and remount, and alternate sign-in. They also show
that an owned identity, stale authentication and other failures leave the account
unchanged. The hosted native storage suite uses real Keychain and a synthetic
backend that enforces single ownership. It confirms interactive reverification of
the current identity, no hint for the linked one and unchanged records after
cancellation. It also covers alternate sign-in on another installation and
recovery after Apple revocation. Owned identities, stale sessions, a different
Apple ID and unlinked provider switches are rejected.

The `registration-link` Mock Mail Session registers with Apple and connects Gmail.
It links the synthetic Google identity, then relaunches with both sign-in methods.
Its native provider follows the
[Google registration rules](google-registration.md#deterministic-evidence).
These checks are deterministic, not real Apple, Google or Convex evidence.

## Protected real qualification

Use signed hosts, a configured Convex development deployment, a test Apple ID and
Google accounts from the [protected Gmail test tenant](gmail-provider-test-tenant.md).
Do not record identity tokens, link tickets or relay addresses in artifacts.

On iPhone, iPad and Mac, register with Apple, link Google, then sign in with
Google on a fresh installation and confirm the Product Account ID matches.
Repeat from Google to Apple. Attempt to link a Google account that registered its
own Product Account, and one with the same email address; confirm both are
rejected. Cancel each session, wait more than five minutes between steps, and
interrupt the network before and after completion. Revoke the Apple ID and recover
with the linked Google sign-in. Record results separately from deterministic
evidence. No real linking pass is claimed until this path has run.
