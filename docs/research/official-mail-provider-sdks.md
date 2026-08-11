# Gmail and iCloud Mail library and protocol options

Research current through: 2026-08-11

## Conclusion

Gmail has maintained official libraries that can remove some of this app's
handwritten OAuth and REST plumbing. Google publishes a supported Apple-platform
REST client, `GoogleAPIClientForREST_Gmail`, and recommends Google Sign-In for
native-app authorization. The REST client is Objective-C exposed to Swift and
callback-shaped, not a native Swift/async Gmail SDK. It is therefore an optional
adapter behind the current provider protocols, not a replacement for the app's
sync, cache, outbox, privacy, or multi-account model.

Apple does not publish a public standalone iCloud Mail client SDK or REST API.
The documented third-party path remains IMAP and SMTP with an app-specific
password. MailKit extends the macOS Mail app; it cannot read an account for a
standalone iOS, iPadOS, or macOS client. Apple's open-source `swift-nio-imap` is
an official IMAP building block, but its own README says it is not ready for
production and it supplies neither SMTP nor a complete mail engine.

Microsoft maintains an official Apple authentication SDK, MSAL for iOS and
macOS, but no maintained production Microsoft Graph service SDK for Swift or
Objective-C. Microsoft's current Graph SDK installation list omits Apple
languages, and its former Objective-C SDK is archived. Direct Graph REST through
`URLSession` is a supported implementation, so the existing Graph client is not
an unsupported workaround. MSAL can plausibly replace the handwritten Microsoft
OAuth/token cache; no current official service library should replace the Graph
mail client.

The accepted direction as of 2026-08-11 is:

1. Preserve provider-native adapters: Gmail continues through the Gmail REST API,
   while iCloud Mail and other Standards-Based Mailbox Connections use IMAP and
   SMTP through the qualified SwiftMail engine.
2. Finish the existing SwiftMail qualification, rollout, handwritten-protocol
   retirement, and live iCloud Mail/Fastmail certification before starting either
   Gmail library qualification ticket.
3. Keep Exchange Online and Microsoft 365 on Microsoft Graph. Qualify MSAL as a
   replacement for Microsoft OAuth only; retain direct REST for the mail API.
4. Qualify the official Gmail REST client and AppAuth/GTMAppAuth independently;
   neither candidate receives a broader migration until its tracer-bullet spike
   proves a net reduction in product-owned risk and code.
5. Keep Google Sign-In as a comparison candidate while its multi-account model
   cannot satisfy independent Gmail Mailbox Connections.
6. Do not schedule work around Apple's newer “Allow” account-authorization flow
   until Apple provides this developer account with public or partner-specific
   implementation documentation.

These choices reaffirm the existing
[provider-native adapter decision](../adr/0011-provider-native-mail-adapters.md)
and [qualified mail-engine decision](../adr/0027-qualified-third-party-mail-protocol-engine.md)
rather than introducing a new architectural boundary.

## Provider/library decision table

| Provider surface         | Option                                                                                                                                                                                         | Option type                        | Maintainer                 | Availability and fit                                                                                                                                                                                                                                                                      | Decision                                                                                                                                                                       |
| ------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------- | -------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Gmail REST               | [`google-api-objectivec-client-for-rest`](https://github.com/google/google-api-objectivec-client-for-rest), product `GoogleAPIClientForREST_Gmail`                                             | Provider library                   | Google                     | Current [v5.4.0](https://github.com/google/google-api-objectivec-client-for-rest/releases/tag/v5.4.0) supports SwiftPM and declares iOS 15/macOS 10.15 minima. It provides generated Gmail queries/models and common transport behavior. It is Objective-C/callback-based.                | Good qualification candidate behind existing Swift protocols; optional because Google also supports direct HTTP/JSON.                                                          |
| Gmail OAuth              | [`GoogleSignIn-iOS`](https://github.com/google/GoogleSignIn-iOS), or lower-level [`GTMAppAuth`](https://github.com/google/GTMAppAuth) + [`AppAuth-iOS`](https://github.com/openid/AppAuth-iOS) | Provider and third-party libraries | Google / OpenID Foundation | Google recommends its current Sign-In SDK for native apps. AppAuth gives more explicit state/scope control and GTMAppAuth connects it to Google's REST stack.                                                                                                                             | Qualify before replacing the custom flow, especially for multiple accounts and exact scope behavior. Do not use archived [`gtm-oauth2`](https://github.com/google/gtm-oauth2). |
| Microsoft Graph mail     | Direct [Microsoft Graph REST](https://learn.microsoft.com/en-us/graph/use-the-api)                                                                                                             | Protocol                           | Microsoft                  | Microsoft's [current SDK list](https://learn.microsoft.com/en-us/graph/sdks/sdk-installation) includes .NET, Go, Java, JavaScript, PHP, PowerShell, and Python—not Swift or Objective-C. The former [`msgraph-sdk-objc`](https://github.com/microsoftgraph/msgraph-sdk-objc) is archived. | Keep the existing typed `URLSession` client. There is no maintained official Apple Graph service SDK to adopt.                                                                 |
| Microsoft OAuth          | [`microsoft-authentication-library-for-objc`](https://github.com/AzureAD/microsoft-authentication-library-for-objc) (MSAL)                                                                     | Provider library                   | Microsoft                  | Current [v2.14.1](https://github.com/AzureAD/microsoft-authentication-library-for-objc/releases/tag/2.14.1) is maintained, MIT-licensed, SwiftPM-distributed, and supports multiple cached accounts. Its current package declares iOS 16/macOS 11 minima.                                 | Strong OAuth qualification candidate; retain product account identity, device-only storage/privacy policy, and adapter seams.                                                  |
| iCloud mailbox access    | IMAP `imap.mail.me.com:993` and SMTP `smtp.mail.me.com:587`                                                                                                                                    | Protocol                           | IETF / Apple service       | Apple's [published server settings](https://support.apple.com/en-us/102525) require TLS, authentication, and an app-specific password; POP is unsupported.                                                                                                                                | Keep the generic IMAP/SMTP implementation or use a qualified complete third-party mail engine.                                                                                 |
| Apple Mail integration   | [MailKit](https://developer.apple.com/documentation/mailkit)                                                                                                                                   | System API                         | Apple                      | A macOS Mail app-extension API for compose, message actions, content blocking, and message security. Apple's [WWDC21 introduction](https://developer.apple.com/videos/play/wwdc2021/10168/) describes extensions hosted by Mail.                                                          | Not applicable to the standalone client's transport or sync.                                                                                                                   |
| Apple IMAP protocol code | [`apple/swift-nio-imap`](https://github.com/apple/swift-nio-imap)                                                                                                                              | Provider library                   | Apple                      | Type-safe IMAP parser/encoder and NIO handlers. The project explicitly says it is still in development and not ready for production. It has no SMTP, MIME, auth UX, durable sync, or local store.                                                                                         | Parser experiment only; not a production engine replacement today.                                                                                                             |
| System composer          | [`MFMailComposeViewController`](https://developer.apple.com/documentation/messageui/mfmailcomposeviewcontroller)                                                                               | System API                         | Apple                      | Presents a user-editable message that the system Mail app queues for sending. It cannot read/sync mail or provide this app's durable outbox semantics.                                                                                                                                    | Not applicable to the core client.                                                                                                                                             |

Google's [Gmail client-library page](https://developers.google.com/workspace/gmail/api/downloads)
explicitly says any HTTP client can call the API and lists the Objective-C
library for Apple platforms. Adopting GTLR is therefore a code-maintenance choice,
not a protocol requirement.

## Plausible replacement boundary in this repository

| Current code                                                                                                                                                                            | What an official library could replace                                                                                                                                                                       | What must remain product-owned                                                                                                                                                                                                                                                               |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`GoogleGmailOAuthService.swift`](../../apps/unwired-mail/unwired-mail/Services/ProductAccount/GoogleGmailOAuthService.swift)                                                           | Authorization URL/session lifecycle, PKCE, authorization-code exchange, refresh coordination, and OAuth response models through Google Sign-In or AppAuth/GTMAppAuth.                                        | Multi-account selection, `ThisDeviceOnly` Keychain policy, product error/UX mapping, required-grant checks, disconnect/revocation behavior, and the existing `GmailOAuthAuthorizing` seam.                                                                                                   |
| [`GmailProviderConnectionService.swift`](../../apps/unwired-mail/unwired-mail/Services/ProductAccount/GmailProviderConnectionService.swift)                                             | Parts of `GoogleGmailProviderCredentialVerifier`: token authorization, Gmail profile query, and token refresh.                                                                                               | Account-identity matching, accepted-scope policy, connection persistence, device trust, and provider-domain errors.                                                                                                                                                                          |
| [`GmailMessageMetadataService.swift`](../../apps/unwired-mail/unwired-mail/Services/Gmail/GmailMessageMetadataService.swift)                                                            | Page-request construction, generated request/response DTOs, response decoding, uploads, retry hooks, and Gmail methods for labels, messages, history, modify, and send.                                      | Cursor persistence, resumable page commits, bounded initial availability, continuation validation, final-page reconciliation, history-expiry recovery, local presentation/cache updates, category behavior, action semantics, and provider-independent protocols.                            |
| [`GmailMessageBodyService.swift`](../../apps/unwired-mail/unwired-mail/Services/Gmail/GmailMessageBodyService.swift)                                                                    | Gmail `messages.get` and attachment queries plus generated response types.                                                                                                                                   | MIME/body interpretation, HTML/text policy, attachment limits, cache and privacy behavior.                                                                                                                                                                                                   |
| [`GmailPushRelayService.swift`](../../apps/unwired-mail/unwired-mail/Services/Gmail/GmailPushRelayService.swift)                                                                        | Gmail `watch` and `stop` request/response plumbing.                                                                                                                                                          | Pub/Sub relay, watch renewal, account routing, notification deduplication, fallback sync, and privacy boundaries.                                                                                                                                                                            |
| [`MicrosoftGraphMailboxConnectionAdapter.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/MicrosoftGraphMailboxConnectionAdapter.swift)                                    | MSAL could replace `MicrosoftGraphOAuthService` authorization-code/PKCE exchange, refresh-token handling, token caching, broker/Conditional Access support, and OAuth response models.                       | Preserve `MicrosoftGraphAuthorizing`, independent Mailbox Connections, device-local authorization policy, account verification, scope checks, domain errors, and disconnect cleanup.                                                                                                         |
| [`MicrosoftGraphMailboxConnectionAdapter.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/MicrosoftGraphMailboxConnectionAdapter.swift) (`URLSessionMicrosoftGraphClient`) | No maintained official Apple Graph service SDK. Archived SDK or experimental generated code could only replace page-request construction, DTOs, and response decoding while adding unsupported dependencies. | Keep cursor persistence, resumable page commits, bounded initial availability, continuation validation, final-page reconciliation, delta synchronization, immutable-ID handling, draft/idempotency reconciliation, MIME/body policy, local cache, Outbox, actions, and provider abstraction. |
| [`MicrosoftGraphPushRelayService.swift`](../../apps/unwired-mail/unwired-mail/Services/MicrosoftGraph/MicrosoftGraphPushRelayService.swift)                                             | No current Apple Graph SDK replacement; an SDK would at most wrap subscription CRUD.                                                                                                                         | Preserve public webhook validation/routing, `clientState`, renewal, lifecycle/missed-notification recovery, APNs delivery, reconciliation, trusted-device fencing, and the minimal-metadata privacy boundary.                                                                                |
| [`SystemIMAPMailboxClient.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/SystemIMAPMailboxClient.swift)                                                                  | `swift-nio-imap` could replace low-level IMAP grammar parsing/encoding in a prototype.                                                                                                                       | TLS/connection lifecycle, auth, capability negotiation, durable mailbox sync, reconnect, storage, and SMTP.                                                                                                                                                                                  |
| [`SystemGenericMailEndpointVerifier.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/SystemGenericMailEndpointVerifier.swift)                                              | A complete mail engine could replace raw IMAP/SMTP/POP connection and protocol verification; `swift-nio-imap` covers only the IMAP grammar portion.                                                          | Provider discovery, credential policy, product errors, privacy controls, and setup UX.                                                                                                                                                                                                       |
| [`GenericMailProviderCatalog.swift`](../../apps/unwired-mail/unwired-mail/Services/Mailbox/GenericMailProviderCatalog.swift)                                                            | Nothing useful: its iCloud endpoint profile already matches Apple's public settings.                                                                                                                         | Keep explicit provider metadata and app-password preference.                                                                                                                                                                                                                                 |

This boundary agrees with the existing [IMAP/SMTP offload research](imap-smtp-library-offload.md):
a complete generic mail engine is more valuable than replacing only an IMAP
parser. The official Google client is different because it covers the full Gmail
REST surface while preserving the app's provider adapter.

## Gmail constraints

### Authentication and multiple accounts

Google's [OAuth 2.0 guide for native apps](https://developers.google.com/identity/protocols/oauth2/native-app)
requires an installed-app client, system-browser authorization, redirect handling,
and PKCE; a native app cannot safely keep a client secret. Workspace
administrators may also block requested scopes.

Google Sign-In is maintained and cross-platform, but its issue tracker exposes
material qualification risks for this product:

- [#311](https://github.com/google/GoogleSignIn-iOS/issues/311) remains open for
  first-class multiple-account state. This app supports multiple Gmail mailboxes,
  so a singleton/current-user integration is not a drop-in token store.
- [#440](https://github.com/google/GoogleSignIn-iOS/issues/440) remains open
  because the SDK adds `email` and `profile` scopes.
- [#407](https://github.com/google/GoogleSignIn-iOS/issues/407) documents
  `include_granted_scopes=true` surfacing previously granted scopes.
- [#578](https://github.com/google/GoogleSignIn-iOS/issues/578) reports an open
  authentication-completion failure when `ASWebAuthenticationSession` is
  interrupted by device lock.

Independent AppAuth authorization-state objects may fit multiple local accounts
better, but must be qualified against the current Keychain format and token
rotation. AppAuth [v2.1.0](https://github.com/openid/AppAuth-iOS/releases/tag/2.1.0)
removed a Safari fallback that had triggered App Review reports in
[#933](https://github.com/openid/AppAuth-iOS/issues/933). An open
[#947](https://github.com/openid/AppAuth-iOS/issues/947) reports an Xcode 26.4
warning-as-error build failure, so the exact app/Xcode matrix must be tested
before adoption.

### REST client maturity and integration cost

GTLR v5.4.0 is actively generated and Apache-2.0 licensed. Its generated Gmail
surface includes messages, attachments, labels, history, watch, stop, modify,
and send. However:

- [GTLR #234](https://github.com/google/google-api-objectivec-client-for-rest/issues/234)
  remains open for a Swift example. A maintainer confirms the library is
  supported and its service definitions update regularly, but callers still
  receive Objective-C-shaped APIs.
- Closed [#607](https://github.com/google/google-api-objectivec-client-for-rest/issues/607)
  records Xcode indexing the multi-service package. The maintainer says only
  selected targets build/link, but indexing cost should be measured.
- [`USING.md`](https://github.com/google/google-api-objectivec-client-for-rest/blob/v5.4.0/USING.md)
  documents HTTP request/response logging. It must stay disabled or be strictly
  redacted because URLs, headers, and payloads may contain mailbox data or tokens.

The library's Apache-2.0 license is compatible with ordinary application use,
subject to preserving required notices. Google Sign-In, GTMAppAuth, AppAuth, and
`swift-nio-imap` are also Apache-2.0 projects. Dependency licenses still require
the project's normal release review.

### Google policy, review, quota, and push

The current app requests `gmail.modify`. Google's [scope table](https://developers.google.com/workspace/gmail/api/auth/scopes)
classifies it as restricted. It permits reading, composing, sending, and modifying
mail, but not immediate permanent deletion. Public use requires restricted-scope
verification. Google's [Workspace API user-data policy](https://developers.google.com/workspace/workspace-api-user-data-developer-policy)
recognizes built-in email clients as an approved use but requires least privilege,
clear disclosures and consent, secure handling, user deletion support, and Limited
Use compliance. The [verification requirements](https://support.google.com/cloud/answer/13464321)
and [security-assessment guidance](https://support.google.com/cloud/answer/13465431)
make clear that using an official SDK does not waive review. Storing or
transmitting restricted-scope data through a server requires an annual security
assessment. The Gmail push relay receives only transient Minimal Push Metadata;
it neither persists nor logs that metadata and discards it after routing. Because
the relay still transmits restricted-scope data, it remains within assessment
scope unless Google confirms that this specific routing boundary is exempt.

For projects created on or after 2026-05-01, Google's current [Gmail API quota](https://developers.google.com/workspace/gmail/api/reference/quota)
is 1,200,000 units/minute/project and 6,000 units/minute/user/project, with an
80,000,000-unit daily no-charge threshold before future pricing. Operation costs
vary substantially (`messages.get` is 20 units and `messages.send` is 100). Those
limits apply equally to GTLR and direct `URLSession` calls.

Gmail [push notifications](https://developers.google.com/workspace/gmail/api/guides/push)
still require Cloud Pub/Sub, watch renewal at least every seven days, and recovery
for delayed/dropped notifications. Gmail caps notifications at one event per
second per user. The [sync guide](https://developers.google.com/workspace/gmail/api/guides/sync)
requires a full resync when a stored history ID is too old and `history.list`
returns 404. A client library does not remove any of that state-management work.

Using Gmail IMAP/SMTP instead would not avoid review: Google's
[XOAUTH2 protocol guide](https://developers.google.com/workspace/gmail/imap/xoauth2-protocol)
uses the full restricted `https://mail.google.com/` scope, and Google recommends
granular Gmail API scopes when full mailbox protocol access is unnecessary.

## Microsoft Graph and Exchange Online constraints

### Service SDK and authentication boundary

Microsoft's supported [Graph SDK installation matrix](https://learn.microsoft.com/en-us/graph/sdks/sdk-installation)
has no Swift or Objective-C SDK. The archived Objective-C repository's open
[#45](https://github.com/microsoftgraph/msgraph-sdk-objc/issues/45) records the
maintenance gap, and [#40](https://github.com/microsoftgraph/msgraph-sdk-objc/issues/40)
never delivered SwiftPM support. Microsoft's Kiota generator is not a production
escape hatch: Swift remains [experimental](https://learn.microsoft.com/en-us/openapi/kiota/using),
and its [Swift runtime, serialization, HTTP, and Azure-auth dependencies are not
released](https://learn.microsoft.com/en-us/openapi/kiota/dependencies). Continue
calling the documented `v1.0` REST API directly rather than adopting archived or
experimental service code.

MSAL is different: Microsoft maintains it specifically for iOS/macOS, and its
[current package](https://github.com/AzureAD/microsoft-authentication-library-for-objc/blob/2.14.1/Package.swift)
is a SwiftPM binary for iOS 16+, macOS 11+, and visionOS 1+. Microsoft documents
[multiple-account enumeration and silent token acquisition](https://learn.microsoft.com/en-us/entra/msal/objc/install-and-configure-msal),
so it fits independent Microsoft Mailbox Connections better than Google
Sign-In's current account model. Qualification still needs interactive/silent
flow, broker and Conditional Access, cancellation, account removal, Keychain
sharing, and strict concurrency coverage. The latest release was itself a
[redirect-loop/browser-handoff hotfix](https://github.com/AzureAD/microsoft-authentication-library-for-objc/releases/tag/2.14.1),
open [#817](https://github.com/AzureAD/microsoft-authentication-library-for-objc/issues/817)
leaves second-personal-account selection unclear, and open
[#1780](https://github.com/AzureAD/microsoft-authentication-library-for-objc/issues/1780)
reports a macOS authentication window hidden behind the app.

MSAL's [privacy manifest](https://github.com/AzureAD/microsoft-authentication-library-for-objc/blob/2.14.1/MSAL/PrivacyInfo.xcprivacy)
declares several linked data categories, including name, email address, user ID,
device ID, and diagnostic data. Its [logging guidance](https://learn.microsoft.com/en-us/entra/msal/objc/logging-ios)
says PII logging is off by default but warns that MSAL logs can be sensitive.
Before adoption, reconcile the manifest with App Store disclosures, keep PII
logging disabled, and verify that telemetry/cache behavior preserves the
device-held-token boundary.

### Graph versus Exchange protocols

Microsoft's Exchange development guidance calls Graph the
[recommended API for Exchange Online data](https://learn.microsoft.com/en-us/exchange/client-developer/exchange-server-development).
OAuth-authenticated IMAP/POP/SMTP remains technically supported, but Microsoft
explicitly recommends either modernizing those protocols with OAuth or migrating
to Graph. Basic authentication has already been removed for most Exchange Online
protocols; the Exchange team's [current SMTP AUTH timeline](https://techcommunity.microsoft.com/blog/exchange/updated-exchange-online-smtp-auth-basic-authentication-deprecation-timeline/4489835)
disables Basic SMTP AUTH by default for existing Exchange Online tenants at the
end of December 2026 and retains OAuth as the supported method. This default-off
change is distinct from permanent removal; Microsoft has not announced the final
removal date. Exchange Online EWS begins worldwide disablement in October 2026
and is [fully disabled in April 2027](https://learn.microsoft.com/en-us/exchange/clients-and-mobile-in-exchange-online/deprecation-of-ews-exchange-online).
The accepted ADR 0011 split is therefore still correct: Graph for Exchange Online
and Microsoft 365, EWS only for supported on-premises Exchange, and IMAP/SMTP for
standards-based providers—not as the primary Exchange Online adapter.

The current delegated `Mail.ReadWrite` and `Mail.Send` permissions are available
for both organizational and personal Microsoft accounts and do not intrinsically
require admin consent, according to the [Graph permissions reference](https://learn.microsoft.com/en-us/graph/permissions-reference).
Tenant consent policy can nevertheless require administrator approval. Microsoft
recommends a [verified publisher](https://learn.microsoft.com/en-us/entra/identity-platform/publisher-verification-overview)
for multitenant apps, and risk-based consent can step an unverified app up to
admin approval. Supporting Outlook.com as well as organizations requires the
appropriate multitenant-plus-personal [account audience](https://learn.microsoft.com/en-us/entra/identity-platform/single-and-multi-tenant-apps).

Graph does not remove product synchronization or push logic. Message delta is
per-folder; opaque tokens can expire or reset, and a `410 Gone` requires full
resynchronization under the [delta-query contract](https://learn.microsoft.com/en-us/graph/delta-query-overview).
Outlook subscriptions expire in under seven days, require an HTTPS webhook and
renewal, can report missed/removed subscriptions, and are limited to 1,000 active
subscriptions per mailbox under the [change-notification contract](https://learn.microsoft.com/en-us/graph/outlook-change-notifications-overview).
Outlook throttling is also enforced per app/mailbox; callers must honor `429` and
`Retry-After` under Microsoft's [service-specific limits](https://learn.microsoft.com/en-us/graph/throttling-limits).
Finally, the current hard-coded global login and Graph endpoints exclude isolated
[national cloud deployments](https://learn.microsoft.com/en-us/graph/deployments),
whose tokens and endpoints are not interchangeable with the global service.

## Apple and iCloud Mail constraints

### Publicly documented access

Apple's [iCloud Mail server settings](https://support.apple.com/en-us/102525) are
the authoritative public integration surface: IMAP over TLS on port 993 and SMTP
with TLS/STARTTLS on port 587. Apple explicitly says iCloud Mail does not support
POP. Apple's [app-specific-password guidance](https://support.apple.com/en-us/102654)
requires two-factor authentication, allows at most 25 active passwords, and
revokes all of them after the primary Apple Account password is changed or reset.
The app therefore needs explicit revocation/reconnect UX and device-only secret
storage.

Apple now tells users that some [supported third-party apps](https://support.apple.com/en-us/121539)
can request an “Allow” flow for iCloud Mail, Contacts, and Calendar. As of the
research date, Apple has not published a general developer SDK, entitlement,
qualification process, scopes, endpoints, or token-lifecycle documentation for
this flow. A May 2026 [Apple Developer Forums question](https://developer.apple.com/forums/topics/app-and-system-services/app-and-system-services-icloud-and-data?page=3&sortBy=lastUpdated)
asks how third parties can qualify and has not yielded usable public integration
documentation. This supports only a documentation-gap finding—not a claim that
private or partner access does not exist. The safe baseline remains app-specific
passwords; ask Apple Developer Technical Support before planning an authorization
migration.

### `swift-nio-imap` readiness

Apple's library is useful protocol infrastructure, but its current issue tracker
matches its pre-production warning:

- [#555](https://github.com/apple/swift-nio-imap/issues/555) is open for a
  re-entrancy problem involving queued commands and continuation requests.
- [#750](https://github.com/apple/swift-nio-imap/issues/750) is open for a
  complete client-channel-handler example.
- [#824](https://github.com/apple/swift-nio-imap/issues/824) is open around
  `Sendable` and Swift concurrency use of `IMAPClientHandler`.
- [#225](https://github.com/apple/swift-nio-imap/issues/225) is open for
  streaming message-body transfer decoding.
- [#772](https://github.com/apple/swift-nio-imap/issues/772), a network framing
  bug when CR/LF was split across inbound buffers, was fixed only in March 2026.

These do not make the library unusable for a controlled experiment, but they do
make a wholesale production replacement unjustified. It also cannot replace the
SMTP half of iCloud sending.

### Availability, background behavior, and privacy

iOS background execution is constrained: Apple's [background execution guidance](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
describes only a short period to finish work after entering the background, and
[App Review guideline 2.5.4](https://developer.apple.com/app-store/review/guidelines/)
limits background services to their intended purposes. A persistent iCloud IMAP
IDLE connection is therefore not a reliable iOS background-push design. With no
documented iCloud provider-push API, freshness is best effort unless a backend
holds credentials and polls, which would materially change this product's privacy
boundary.

Apple's [App Privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)
say data processed only on-device is not “collected”; off-device data retained
beyond servicing a real-time request is. The app must include third-party SDK
behavior in its disclosures. Adding an SDK does not itself require new disclosure,
but enabling HTTP body logging, telemetry, or server persistence of addresses or
message content could. Audit each dependency's privacy manifest and runtime
network behavior before release.

## Accepted qualification sequence

1. **Finish SwiftMail first:** complete deterministic qualification in
   [#428](https://github.com/unwired-dev/product/issues/428), the existing
   Standards-Based Mailbox Connection rollout through
   [#183](https://github.com/unwired-dev/product/issues/183), and live iCloud Mail
   and Fastmail certification in
   [#280](https://github.com/unwired-dev/product/issues/280). The Gmail spikes do
   not begin until both #183 and #280 are complete.
2. **Prepare the isolated Gmail environment:** complete
   [#303](https://github.com/unwired-dev/product/issues/303) so provider-backed
   qualification cannot touch personal or production identities or resources.
3. **GTLR spike:** execute
   [#434](https://github.com/unwired-dev/product/issues/434), wrapping one
   read-only Gmail method in Swift async/await behind an existing protocol and
   comparing binary size, clean-build and Xcode indexing time, cancellation,
   retry semantics, errors, privacy logging, fixture determinism, and removed
   code against the current `URLSession` implementation.
4. **OAuth spike:** independently execute
   [#435](https://github.com/unwired-dev/product/issues/435), exercising multiple
   Gmail Mailbox Connections, incremental consent, cancellation and device-lock
   behavior, refresh-token rotation, identity matching, revocation, and
   `ThisDeviceOnly` Keychain persistence through AppAuth/GTMAppAuth. Google
   Sign-In remains comparison-only unless it passes the same independent-account
   contract.
5. **MSAL spike:** independently qualify MSAL behind
   `MicrosoftGraphAuthorizing`, exercising simultaneous organizational and
   personal accounts, interactive and silent acquisition, broker and Conditional
   Access behavior, cancellation, account removal, Keychain policy, privacy
   disclosures, and iOS/macOS presentation. Keep the existing Graph REST client.
6. **Expand only if earned:** if a spike is smaller and no less observable,
   propose a separately approved migration of Gmail request/DTO or OAuth plumbing.
   Keep synchronization, cache, Outbox, push relay, MIME interpretation, and
   privacy policy outside the adapters. If a candidate fails, remove the
   experimental path instead of retaining a second implementation.
7. **Apple authorization inquiry:** independently ask Apple Developer Technical
   Support whether the third-party “Allow” flow is generally available, what
   entitlement or review is required, and whether it supports iOS and macOS
   standalone mail clients. Treat any answer as a new architecture input rather
   than a blocker for IMAP/SMTP delivery.

## Remaining uncertainties

- Whether Google will require this exact device-local plus transient-push-relay
  architecture to complete an annual restricted-scope security assessment.
- Whether Google Sign-In can safely support the product's simultaneous local
  multi-account lifecycle despite the open multiple-account issue.
- Whether AppAuth 2.1.0 builds cleanly with the repository's exact Xcode version
  and strict warning settings.
- Whether MSAL's account selection, broker/Keychain behavior, privacy manifest,
  and macOS presentation preserve independent Mailbox Connection semantics.
- Whether Apple's newer account-authorization flow is open to independent mail
  clients, partner-gated, or subject to a private entitlement.
- iCloud IMAP extension support, practical throttling, and server behavior are not
  contractual in Apple's public settings article and require provider fixtures.
