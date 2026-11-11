# Browser mail client and extension evaluation

[#1664](https://github.com/unwired-dev/product/issues/1664) asks whether a
private browser mail client or browser extension, comparable to Superhuman's
browser client and Chrome extension (scope SH-012), fits the product's privacy
model. It changes no runtime, registration or credential, and it does not
authorize browser delivery. Official sources were read on 2026-11-11.

## Decision

**No-go** for a browser mail client or a Chrome extension. Each would break an
accepted boundary: provider tokens would sit in JavaScript-readable browser storage
([ADR 0067](adr/0067-keep-native-code-to-a-minimal-vault.md)), the browser would
need a new provider registration with weaker renewal, IMAP would need a server
relay, and Private Cloud Compute is out of reach. A supported fix exists for none
of these boundaries. The owner can reopen this evaluation through a new issue that
accepts specific trade-offs from [Boundaries](#boundaries).

A Safari web extension bundled with the Mac host is the only shape that keeps
tokens, keys and PCC in the native vault. It still requires
[an owner decision](#safari-companion-not-proposed) and is not proposed here: it
renders only what the Mac host can already show, and it does not provide SH-012's
main benefit, which is mail in a browser on a machine without the app.

## Prototype

Not run. The bounded sign-in, read and sign-out prototype is blocked before any
mailbox is touched:

- **Google.** The hosts register one native iOS OAuth client and configure no web
  client, client secret or web redirect
  ([native credentials](google-registration.md#native-credentials-and-verification)).
  A browser cannot finish Google consent for the product's client. A web client is
  an owner action in Google Cloud, and Google verifies each client submitted.
  Gmail's provider test account is also blocked
  ([#1528](https://github.com/unwired-dev/product/issues/1528)).
- **Microsoft.** There is no Entra test tenant for a single-page application
  registration ([#633](https://github.com/unwired-dev/product/issues/633)).
- **Production mail is excluded** by the issue and
  [ADR 0032](adr/0032-use-only-synthetic-mail-in-test-environments.md).

A prototype would leave each of the boundaries below unresolved, so these blockers
do not change the decision.

## Boundaries

### Provider authorization

- **Gmail.** Google's
  [token model](https://developers.google.com/identity/oauth2/web/guides/use-token-model)
  gives browser apps only short-lived access tokens. "By design, access tokens
  have a short lifetime." When a token expires before the session ends, the app
  calls `requestAccessToken()` again "from a user-driven event such as a button
  press", and "only the dialog UX is supported". There is no background refresh
  like the hosts' device-held grant. The
  [implicit flow](https://developers.google.com/identity/protocols/oauth2/javascript-implicit-flow)
  returns no refresh token either, and Google calls it insecure for single-page
  apps. A new web client would also need verification of its own. Push wakes would
  need a relay change, because the relay verifies one `GMAIL_OAUTH_CLIENT_ID`.
- **Microsoft.** Refresh tokens issued to a `spa` redirect "expire after 24
  hours". Apps must then rerun interactive authorization in a top-level frame
  ([Microsoft identity platform](https://learn.microsoft.com/en-us/entra/identity-platform/refresh-tokens)).
- **IMAP.** Ordinary web apps "cannot establish raw TCP or UDP connections".
  Direct Sockets is "restricted to Isolated Web Apps", which are Chrome apps the
  user installs explicitly
  ([Direct Sockets](https://developer.chrome.com/docs/iwa/direct-sockets)). Any
  other route to IMAP and SMTP from a browser needs a server relay that sees
  readable mail and credentials. That contradicts
  [ADR 0002](adr/0002-device-held-mail-provider-tokens-with-push-relay.md), and
  the issue rules it out.
- **Chrome extension.** `chrome.identity.getAuthToken` returns a Google access
  token for an account in the Chrome profile. Other providers use
  `launchWebAuthFlow` through a `https://<app-id>.chromiumapp.org/` redirect
  ([chrome.identity](https://developer.chrome.com/docs/extensions/reference/api/identity)).
  Either route needs a new provider registration for the extension's client and
  hands tokens to extension JavaScript.

### Storage and trust

- **Tokens enter JavaScript.** The hosts keep refresh credentials and access tokens
  out of JavaScript and Convex
  ([native credentials](google-registration.md#native-credentials-and-verification),
  [Microsoft credentials](microsoft-mail.md#credentials)), in a ThisDeviceOnly
  Keychain item ([ADR 0010](adr/0010-device-local-mailbox-authorization.md)).
  Browser storage has no equivalent of that item. A browser client would hold
  tokens, the cache key and its Trusted Device key where any script running in
  its origin can read them.
- **Storage can disappear.** Safari deletes "all cookies created in JavaScript and
  all other script-writeable storage", including IndexedDB and service worker
  registrations, "after 7 days of no user interaction with the website". Home
  screen web apps are exempt
  ([WebKit tracking prevention](https://webkit.org/tracking-prevention/)). A
  Trusted Device key lost this way leaves a Pending Device that must be
  re-approved.
- **Every browser is a device.** Private Sync's cryptography is portable: the
  TypeScript `@noble` libraries already seal approvals in
  `packages/mail-core/src/testing/enrollment-approval.ts`. But each browser
  profile would become a Trusted Device, admitted with an Enrollment Code or the
  Recovery Key and counted against the three-device limit
  ([ADR 0066](adr/0066-admit-devices-only-through-authorized-enrollment.md),
  [approving a new device](private-product-sync.md#approving-a-new-device)).
  Each key rotation would also seal to it
  ([ADR 0070](adr/0070-seal-key-rotations-to-each-remaining-trusted-device.md)).
- **Extension code is fixed.** Manifest V3 requires that "all of your extension's
  logic must be part of the extension package", with no remotely hosted code
  ([Chrome extension security](https://developer.chrome.com/docs/extensions/develop/migrate/improve-security)).
  That limits supply-chain exposure, but the extension still runs inside the
  browser and next to other extensions.

### Account removal

[Sign-out and Product Account deletion](account-removal.md#what-is-removed) remove
local credentials, the cache and keys from a device. A browser could clear its own
origin storage on sign-out, but not when it is closed or offline. If Safari has
already deleted the Trusted Device key,
only [removing that Trusted Device](private-product-sync.md#removing-a-trusted-device)
from another Trusted Device takes it out of the key ring. A revoked browser keeps
whatever it already decrypted until its storage is cleared.

### Private Cloud Compute

Apps reach PCC only through the Foundation Models framework
(`PrivateCloudComputeLanguageModel`). It runs on Apple Intelligence devices with
a managed entitlement and a per-user daily limit
([WWDC26 session 319](https://developer.apple.com/videos/play/wwdc2026/319/),
[What's new in Foundation Models](https://developer.apple.com/videos/play/wwdc2026/241/)).
No source describes a web or REST API.
[ADR 0075](adr/0075-prefer-private-cloud-compute-for-separately-authorized-mail-assistance.md)
keeps PCC in native sessions with no backend inference service. A browser client
would therefore have no
[Private Cloud Mail Assistance](product/private-cloud-mail-assistance.md), and
routing it through a server would break both ADRs.

## Safari companion: not proposed

A Safari web extension ships inside the containing app. Its background script or
extension pages, but not its content scripts, can call
`browser.runtime.sendNativeMessage`, and Safari delivers the message only to "the
containing app's native app extension". Only a containing macOS app can send
messages back to the extension's scripts, using `connectNative` and
`SFSafariApplication.dispatchMessage`
([Safari web extension messaging](https://developer.apple.com/documentation/safariservices/messaging-between-the-app-and-javascript-in-a-safari-web-extension)).
The app and the native app extension run in separate sandboxes and "cannot share
data in their respective containers" except through an app group. Reaching mail
would therefore need a new vault channel that hands sanitized content to the
extension and keeps tokens in the vault. The extension's pages would display
readable mail inside Safari, next to other extensions.

If the owner wants this shape, a new issue approves its value first. The slices
would be:

1. Spike a vault channel from the extension handler that returns sanitized
   synthetic messages and never returns tokens.
2. Design the Light and Dark extension surfaces in Figma and get design approval.
3. Ship a read-only Inbox view to the Mac host and qualify it with Mock Mail
   Sessions.
