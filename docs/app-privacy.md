# App Privacy answers for App Store Connect

Status: draft answers for Unwired Mail on iPhone, iPad and Mac, recorded in
[issue #1966](https://github.com/unwired-dev/product/issues/1966) from the code at
commit `135d15ba4`. This is not a submission and not legal advice. The account
owner submits the answers in App Store Connect, and the
[app privacy notice](https://github.com/unwired-dev/product/issues/1946) must
reconcile with them before release. Revise this page with any change to the data
flows it cites.

## Apple's terms

The answers follow Apple's
[App privacy details](https://developer.apple.com/app-store/app-privacy-details/):

- **Collect** means sending data off the device and storing it in a readable form
  for longer than it takes to service the request. A token or address the backend
  verifies and then discards is not collected. Data processed only on the device
  is not collected.
- **Linked** data is tied to the person's identity through their account, device or
  other details.
- **Email Address** includes a hashed email address.
- **Tracking** means linking app data with other companies' data for advertising or
  advertising measurement, or sharing it with a data broker.

Apple's page does not address end-to-end encryption. These answers treat
ciphertext the backend cannot decrypt as not readable, so not collected. That is
an interpretation for the owner to confirm, not a claim that the data is
anonymous: the ciphertext still exists, is tied to a Product Account and is
deleted with it.
If the owner rejects it, Emails or Text Messages, Photos or Videos and Other
User Content become collected and linked, for App Functionality.

## On-device processing and encrypted sync

Mail and provider OAuth tokens stay on the device. Drafts are written on the
device and leave it only as Private Sync ciphertext. Search, categorization,
summaries, translation and rewrites run on the device. Each device talks to Gmail,
Microsoft Graph and IMAP/SMTP servers directly
([ADR 0002](adr/0002-device-held-mail-provider-tokens-with-push-relay.md)).
Mail assistance uses on-device Foundation Models
(`native/private-inbox/bridge/UnwiredAssistance.swift`). The apps request
Contacts access only to suggest recipients while composing; contacts
are read on the device and never leave it, so they are not collected. A
suggestion the person accepts becomes an ordinary recipient of the Draft
([Drafts](drafts.md#composing)). The apps request no calendar, location, photos,
camera or microphone permission and contain no advertising SDK, advertising
identifier or App Tracking Transparency prompt.

[Private Sync](private-product-sync.md#keys-and-envelopes) stores mailbox
descriptions (provider and address), Drafts and their files and photos
([Draft Assets](drafts.md#continuing-on-another-device)) in Convex as end-to-end
encrypted records (`encryptedProductSyncPayloads`, `productSyncKeyEnvelopes`). Scheduled
sends keep only the encrypted Draft's identifier and timing; a Trusted Device
sends the mail.

## Backend-readable data

The Convex backend stores these fields in readable form
(`packages/convex/convex/schema.ts`):

| Data                                                               | Where                                                     | Why                                      |
| ------------------------------------------------------------------ | --------------------------------------------------------- | ---------------------------------------- |
| Sign-in issuer and subject (Google or Apple)                       | `productAccounts.tokenIdentifier`, `linkedSignIns`        | Product Sign-In and linked sign-in       |
| Random device identifier, platform, generic device name            | `trustedDevices`, `pendingDevices`                        | Trusted Device enrollment and revocation |
| APNs device token and environment                                  | `trustedDevices.apnsToken`                                | New-mail and scheduled-send wakes        |
| Keyed HMAC digest of each Gmail address                            | `mailProviderConnections.gmailRoutingDigest`              | Routing Gmail push wakes                 |
| Opaque connection id, Microsoft Graph subscription id              | `mailProviderConnections`                                 | Routing push wakes                       |
| Send claim times, scheduled-send due times and states              | `draftDeliveryClaims`, `scheduledSends`                   | Sending a Draft once; Scheduled Send     |
| Gmail history ids                                                  | `gmailPushVerificationSignals`, `mailProviderConnections` | Verifying push ownership                 |
| Apple authorization code or tokens, kept across revocation retries | `productAccountDeletionRequests.revocationMaterial`       | Revoking sign-in during account deletion |
| Sign-in subject after deletion                                     | `productAccountDeletionTombstones`                        | Preventing a deleted account's reuse     |

Product Accounts store no name or email address. The backend reads the email
claim of a Google identity token only to derive the Gmail routing digest, then
discards it. Gmail Pub/Sub payloads carry the mailbox address and history id; the
relay derives the digest and keeps no address. APNs payloads carry an opaque
route, provider and Gmail history id. The clients send no device name, so
Trusted Devices keep the generic `Apple mobile device` or `Mac` name
(`packages/convex/convex/productAccount.ts`).
[Product Account deletion](account-removal.md) removes the account's records and
keeps the tombstone.

## Opt-in error reporting

[Error reporting](telemetry.md#error-reporting-implementation) is off by default,
including for upgrades, and turns on only after the person enables it. The app
sends reports to Convex, which forwards them to PostHog EU with GeoIP disabled.
A report carries a random installation id unrelated to the Product Account,
predefined failure codes, approved constant messages, stack addresses, up to 50
operation stages with elapsed milliseconds and HTTP status, and the app version,
build, OS version, platform and release channel. No mail, account identity or
free text is sent. Unsent reports expire on the device after 24 hours, and
**Delete my error reports** deletes delivered reports at PostHog.

The code ships, but no reporting service is provisioned and release
qualification has not passed. Native collection stays off until
`UNWIRED_NATIVE_ERROR_REPORTING_QUALIFIED` is enabled after
[#1050](https://github.com/unwired-dev/product/issues/1050), and the receiver
fails closed until the `POSTHOG_*` Convex variables are configured. Apple requires
disclosing data collected on an ongoing basis after one permission request, so
the diagnostics answers below apply from the first build that connects the
service. Until then, leave them out of the answers and the
[privacy manifests](#privacy-manifests).

Product analytics, cloud mail assistance through Private Cloud Compute
([#1451](https://github.com/unwired-dev/product/issues/1451)), customer support
([#1945](https://github.com/unwired-dev/product/issues/1945)) and purchases
([#1948](https://github.com/unwired-dev/product/issues/1948)) are not shipped.
Each needs new answers before it is enabled.

## Draft answers

Data used to track you: **none**. No data is used for third-party advertising,
developer advertising or marketing, analytics or product personalization.

| Category     | Data type               | Collected                                | Linked | Purpose           | Evidence                                                                              |
| ------------ | ----------------------- | ---------------------------------------- | ------ | ----------------- | ------------------------------------------------------------------------------------- |
| Identifiers  | User ID                 | Yes                                      | Yes    | App Functionality | Sign-in issuer and subject                                                            |
| Identifiers  | Device ID               | Yes                                      | Yes    | App Functionality | Trusted Device identifier, APNs token; installation id once reporting connects        |
| Usage Data   | Product Interaction     | Yes                                      | Yes    | App Functionality | Send claim times, scheduled-send times and states, account and device last-seen times |
| Other Data   | Other Data Types        | Yes                                      | Yes    | App Functionality | Sign-in tokens kept while account-deletion revocation retries                         |
| Contact      | Email Address           | Yes                                      | Yes    | App Functionality | Keyed Gmail address digest, which Apple counts as a hashed email address              |
| Diagnostics  | Crash Data              | When reporting connects                  | Yes    | App Functionality | Exception names, codes and stack addresses                                            |
| Diagnostics  | Performance Data        | When reporting connects                  | Yes    | App Functionality | Operation elapsed milliseconds                                                        |
| Diagnostics  | Other Diagnostic Data   | When reporting connects                  | Yes    | App Functionality | Breadcrumb stages, HTTP status, app, build, OS version and channel                    |
| User Content | Emails or Text Messages | No: device-local or end-to-end encrypted | —      | —                 | Mail and Drafts; see the encryption interpretation above                              |
| User Content | Photos or Videos        | No: end-to-end encrypted                 | —      | —                 | Photos attached to or inserted in Drafts (Draft Assets)                               |
| User Content | Other User Content      | No: device-local or end-to-end encrypted | —      | —                 | Mailbox descriptions, files attached to Drafts                                        |

Every other data type is not collected: name, phone number, physical address,
health, financial, location, sensitive information, contacts, audio,
browsing and search history, purchases and advertising data.

Three answers are conservative choices for the owner:

- **Email Address** is declared because the routing digest is a keyed hash of
  the address, tied to the Product Account. Declaring nothing would rely on the
  backend-held key making the digest unlike a plain hash, which Apple's page does
  not address.
- **Other Data Types** covers the Sign in with Apple authorization code or
  tokens a deletion request stores; Google sign-in stores none. When Apple revocation times out or fails retryably,
  the request ends and the material stays in
  `productAccountDeletionRequests` until a retry revokes it
  (`packages/convex/convex/productAccountDeletion.ts`), so the real-time
  exemption does not apply.
- **Diagnostics are linked** because the installation id identifies a device,
  though it is not tied to the Product Account. Apple treats data as unlinked only
  when direct identifiers are removed before collection.

Not collected under Apple's definition: identity tokens and Gmail push addresses
verified and discarded in the same request. IP addresses are not stored in the
schema; the owner confirms that Convex and PostHog logs do not retain them in a
readable form beyond servicing requests.

## Privacy manifests

Each app's own privacy manifest declares the five collected types above as
linked, not used for tracking, for App Functionality:
`apps/macos/macos/PrivacyInfo.xcprivacy` on the Mac, and `ios.privacyManifests`
in `apps/mobile/app.config.ts`, which Expo writes into the generated
`PrivacyInfo.xcprivacy` on iPhone and iPad. Change both with the answers. The
[archive inventory](testflight.md#what-the-script-does) records what each
archive declares.

The build that connects error reporting adds
`NSPrivacyCollectedDataTypeCrashData`,
`NSPrivacyCollectedDataTypePerformanceData` and
`NSPrivacyCollectedDataTypeOtherDiagnosticData` to both manifests, also linked,
not tracking, for App Functionality.

## Differences to resolve

| Source                                                                            | Difference                                                                                                                                                                           | Resolution                                                                                                                                              |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Provisional privacy notice](https://www.unwired.dev/privacy)                     | Covers only the website, Product Waitlist and bookings and says nothing about the app.                                                                                               | [#1946](https://github.com/unwired-dev/product/issues/1946) publishes the app notice from this inventory.                                               |
| [Google user data disclosure](google-registration.md#google-user-data-disclosure) | Lists Gmail history ids as stored. The relay keeps received ids for 10 minutes and the last verified id on each connection, which conflicts with ADR 0002's transient push payloads. | The owner resolves the retention conflict ([owner action 1](google-registration.md#remaining-owner-actions)), then updates both pages.                  |
| [ADR 0002](adr/0002-device-held-mail-provider-tokens-with-push-relay.md)          | Legacy Gmail rows registered before opaque routing keep a readable `emailAddress` until their device registers again.                                                                | Before submission, the owner confirms the production deployment has no `mailProviderConnections` or `gmailPushVerificationSignals` row with an address. |
| [Opt-in error reporting](telemetry.md)                                            | Code ships with the receiver disconnected and native collection off.                                                                                                                 | Add the diagnostics answers and manifest types in the release that connects the service.                                                                |
