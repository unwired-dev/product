# App Privacy answers for App Store Connect

Status: proposed answers reconciled on 15 November 2026 for
[issue #2217](https://github.com/unwired-dev/product/issues/2217), following
[#1966](https://github.com/unwired-dev/product/issues/1966). The
[dated evidence record](compliance/app-privacy-2026-11-15.md) distinguishes source,
archive, current production and deferred runtime checks. The account owner submits
the answers in App Store Connect. The [app privacy notice](https://github.com/unwired-dev/product/issues/1946)
must reconcile with them before release. Revise this page when its data flows change.

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

On 15 November 2026 the owner selected broader disclosure for synchronized
Drafts, photos, files and mailbox descriptions. These answers include that content
as collected and linked for App Functionality. This disclosure preserves
end-to-end encryption and device-held keys; it does not authorize readable
content on the backend.

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

## Google SDK collection

GoogleSignIn 10.0.0 declares linked Name, Email Address, Phone Number and Coarse
Location for App Functionality; User ID and Other Data Types for App Functionality
and Analytics; Device ID and Other Usage Data for Analytics. All are declared
not used for tracking. The answers retain these partner declarations. They do not
assert that Unwired stores every type in readable form. Google's SDK adds the
basic `email` and `profile` scopes and sends SDK/version environment metadata;
Unwired requests no phone-number scope. Google describes IP-derived general
location for fraud prevention, which does not require location permission.
[Google SDK disclosure](https://developers.google.com/identity/sign-in/ios/app-privacy),
[pinned-source reconciliation](compliance/app-privacy-2026-11-15.md#google-sign-in).

The SDK privacy page does not explain every category in its broader manifest or
give per-type retention limits. The proposed answers retain those categories and
purposes until version/configuration-specific evidence supports narrowing them.
Google's Analytics purposes are separate from Unwired's unimplemented product
analytics. Clearing the SDK's local sign-in cache does not establish provider
deletion. [Google retention policy](https://policies.google.com/technologies/retention).

## Opt-in error reporting

[Error reporting](telemetry.md#error-reporting-implementation) is off by default,
including for upgrades, and turns on only after the person enables it. The app
sends allowlisted reports to Convex, which forwards them to PostHog EU with GeoIP
disabled. Reports carry an installation id independent of the Product Account,
predefined failure codes, approved constant messages, stack addresses, bounded
operation stages, timings and status, and app/build/OS/platform/channel metadata.
Unsent reports expire locally after 24 hours. **Delete my error reports** uses the
receiver's verified remote-deletion path; signed-device and vendor qualification
remain deferred.

Normal non-mock Release builds with a Convex URL can offer JavaScript reporting.
Debug builds require `UNWIRED_ERROR_REPORTING_QUALIFICATION`.
`UNWIRED_NATIVE_ERROR_REPORTING_QUALIFIED` gates only the disconnected local
Sentry collector and remains off pending
[#1050](https://github.com/unwired-dev/product/issues/1050). Sentry's own transport
is blocked; only its allowlisted projection may use the app's reporting path.
The application's installation identifier makes these diagnostics linked,
regardless of Sentry's unlinked vendor-manifest declarations.

On 15 November, the production backend deployed by the reviewed TestFlight run
had all three `POSTHOG_*` service variables configured. Configuration does not
prove ingestion, deletion or runtime qualification, and the signed archive's
backend still needs matching. The proposed answers include diagnostics because
JavaScript reporting is reachable; the native flag is not a reporting-wide gate.
Recurring collection after one opt-in requires disclosure.
[Observed configuration and limits](compliance/app-privacy-2026-11-15.md#production-observations).

Product analytics, cloud mail assistance through Private Cloud Compute
([#1451](https://github.com/unwired-dev/product/issues/1451)), customer support
([#1945](https://github.com/unwired-dev/product/issues/1945)) and purchases
([#1948](https://github.com/unwired-dev/product/issues/1948)) are not shipped.
Each needs new answers before it is enabled.

## Draft answers

Data used to track you: **none**. No Third-Party Advertising, Developer
Advertising or Marketing, or Product Personalization purpose is declared.
Analytics below reflects Google's SDK declarations.

All rows are collected, linked and not used for tracking. Partner categories are
conservative proposed disclosures, not claims that runtime capture observed every
type.

| Category     | Data type               | Purposes                     | Evidence                                                                |
| ------------ | ----------------------- | ---------------------------- | ----------------------------------------------------------------------- |
| Contact      | Name                    | App Functionality            | Google SDK declaration and basic profile                                |
| Contact      | Email Address           | App Functionality            | Google SDK, keyed Gmail routing digest, encrypted synced address fields |
| Contact      | Phone Number            | App Functionality            | Google SDK declaration; no app phone scope                              |
| Location     | Coarse Location         | App Functionality            | Google SDK declaration and IP-derived fraud prevention                  |
| Identifiers  | User ID                 | App Functionality, Analytics | Sign-in issuer/subject; Google SDK                                      |
| Identifiers  | Device ID               | App Functionality, Analytics | Trusted Device/APNs/reporting installation identifiers; Google SDK      |
| Usage Data   | Product Interaction     | App Functionality            | Send claims, scheduling state and last-seen times                       |
| Usage Data   | Other Usage Data        | Analytics                    | Google SDK declaration                                                  |
| Other Data   | Other Data Types        | App Functionality, Analytics | Retained Apple revocation material; Google SDK                          |
| User Content | Emails or Text Messages | App Functionality            | Synchronized Draft subject, sender, recipients and body                 |
| User Content | Photos or Videos        | App Functionality            | Synchronized Draft photos and images                                    |
| User Content | Other User Content      | App Functionality            | Synchronized Draft files and mailbox descriptions                       |
| Diagnostics  | Crash Data              | App Functionality            | Consented exceptions, codes and stack frames                            |
| Diagnostics  | Performance Data        | App Functionality            | Elapsed operation timings attached to failures                          |
| Diagnostics  | Other Diagnostic Data   | App Functionality            | Allowlisted stages, HTTP status and build/OS/channel metadata           |

The remaining categories have no positive collection evidence in this reviewed
scope. Contacts and on-device assistance remain device-local. Other Data Types
includes Apple authorization material retained across failed revocation retries,
so its real-time processing exemption does not apply. Diagnostics are linked to
an installation even though they are independent of the Product Account.

The schema does not store client IP addresses. That alone does not prove how
Convex or PostHog infrastructure logs handle them. Processor log retention and
actual PostHog project settings remain deferred. PostHog Free event retention is
one year without a guaranteed physical deletion deadline; person profiles remain
until explicit deletion. The local 24-hour queue limit is separate.
[Processor evidence and remaining checks](compliance/app-privacy-2026-11-15.md#remaining-checks).

## Privacy manifests

Each app's own privacy manifest declares the 15 rows above as linked and not used
for tracking, with the listed purposes: `apps/macos/macos/PrivacyInfo.xcprivacy`
and `ios.privacyManifests` in `apps/mobile/app.config.ts`. Expo writes the latter
into the generated iPhone/iPad manifest. Vendor manifests remain intact. Change
both app manifests with these answers. The
[archive inventory](testflight.md#what-the-script-does) records each archive's
actual declarations; the reviewed historical archive predates this correction.

## Differences to resolve

| Source                                                                            | Difference                                                                                                          | Resolution                                                                                                                                                   |
| --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [Provisional privacy notice](https://www.unwired.dev/privacy)                     | Covers the website, Product Waitlist and bookings.                                                                  | [#1946](https://github.com/unwired-dev/product/issues/1946) publishes the app notice using this inventory, including partner and encrypted-sync disclosures. |
| [Google user data disclosure](google-registration.md#google-user-data-disclosure) | Gmail history retention differs from ADR 0002's transient push payloads.                                            | Resolve the existing [retention decision](google-registration.md#remaining-owner-actions).                                                                   |
| [ADR 0002](adr/0002-device-held-mail-provider-tokens-with-push-relay.md)          | Legacy rows can retain a readable address until re-registration.                                                    | The checked production deployment had zero such rows on 15 November. Match the final archive's backend and recheck if different.                             |
| [Error reporting](telemetry.md)                                                   | Native capture is unqualified; JavaScript reporting is reachable and the checked backend has service configuration. | Include diagnostics; complete signed-device, vendor and processor checks without enabling native capture early.                                              |
