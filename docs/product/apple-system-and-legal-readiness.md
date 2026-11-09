# Apple system integration and legal readiness

Confirmed decisions from the requirements interview begun on 2026-11-09,
awaiting final shared-understanding confirmation. This document records agreed
scope, not completed implementation, approved legal documents or passing release
qualification.

## Operator, availability and purchase model

- Unwired, s.r.o. will operate Unwired Mail from the Czech Republic.
- Worldwide public availability is the launch target. Individual territories may
  wait until their applicable declarations, approvals and release requirements
  are satisfied. This decision does not establish legal eligibility or completed
  release checks in any territory.
- Launch access will use an upfront, one-time paid download. One universal
  purchase covers iPhone, iPad and Mac. The price remains undecided.
- The purchase includes the complete launch feature set, including encrypted
  sync and notifications. Existing purchasers retain their purchased launch
  functionality if subscriptions are introduced.
- Future subscriptions are limited to additional optional features or services.
  The launch purchase does not promise every future feature, and no subscription
  is approved for launch.

The [official ARES record](https://ares.gov.cz/ekonomicke-subjekty-v-be/rest/ekonomicke-subjekty/19711131)
identifies Unwired, s.r.o., IČO 19711131, with registered office at Soběšická
184/36, Husovice, 614 00 Brno, Czech Republic, and Commercial Register file
C 135646 at the Regional Court in Brno.

## Audience

Teenagers, including ages 13 through 15, are an intended launch audience. The
product minimum age is 13, subject to applicable local consent and contracting
requirements. The product minimum age does not establish independent consent in
every country.

- Prefer Apple's age-range information and collect only the minimum additional
  information needed when it is insufficient. Do not collect full birthdates or
  identity documents by default. Missing or declined information leaves age
  eligibility unresolved; it does not establish adulthood.
- Defer a parental-consent flow for optional telemetry and cloud AI. Keep those
  features unavailable when the person cannot independently authorize them.
  Purchases and core-app eligibility retain their separate legal requirements.
- Account for shared devices: Apple's age information describes the device's
  iCloud user, which is not necessarily the Product Account owner.
- When platform information is missing or belongs to another person, offer a
  minimal age-band and country declaration where applicable rules permit it.
  When that evidence is insufficient, explain the limitation and keep affected
  access unavailable.

## Existing Apple launch scope

The [power-user launch requirements](power-user-launch.md#native-workflows) and
[issue #854](https://github.com/unwired-dev/product/issues/854) already require
default-mail registration and incoming `mailto:` handling through an editable
Draft, sharing content and files into protected Draft storage, desktop attachment
drag-and-drop, printing and individual message export. Native entry points
preserve Profile and sending context, authentication, Draft-save protection and
cancellation, and never authorize automatic sending.

[ADR 0059](../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
sets App Store distribution for iPhone and iPad and Mac App Store distribution
for Mac. Direct Mac distribution remains separate follow-up work.

### Default-mail setup and incoming links

- Offer to make Unwired Mail the default once after the first Mailbox Connection
  is connected, and keep the action available in Settings. The choice is optional;
  respect dismissal without repeated prompts. The user completes the supported
  system selection.
- An incoming `mailto:` request without a targeted Unwired Profile uses the
  device's **Startup Profile** and its **Default Sending Identity**. Show that
  identity clearly and allow the person to change it before sending.
- Preserve existing unsaved Drafts and require authentication or Profile unlock
  where applicable. Incoming links never authorize automatic sending.
- When signed out or without a ready Profile, explain the required setup and ask
  the person to repeat the incoming link or share action afterward. Do not persist
  incoming content before its owner is established. A signed-in but locked
  Profile can unlock and continue the request.

## Privacy requests

Use `support@unwired.dev` for app support and privacy requests. Verify receipt and
establish monitoring before publishing it. Link the address from the app and
public website.

Handle access, correction, export and other privacy requests initially through
verified manual handling, with documented request verification, applicable
response deadlines and completion evidence. Retain the existing in-app Product
Account deletion and error-report deletion controls. Request handling must
preserve the existing encryption and identity boundaries; support cannot recover
lost encryption keys or promise to erase an unreachable device.

## Public-document reconciliation

Checked on 2026-11-09. The prospective shared
[Terms of Use](https://www.unwired.dev/terms) currently specify a minimum age of
16 and state that no paid Product plan is published. Launch documents must
reflect the newly agreed 13+ audience and paid purchase model.

The provisional [Privacy Notice](https://www.unwired.dev/privacy) covers the
company website. It does not establish coverage of Unwired Mail's processing.

Publish Mail-specific documents at these agreed locations:

- `https://www.unwired.dev/unwired-mail/privacy` for the app privacy notice.
- `https://www.unwired.dev/unwired-mail/terms` for its service terms.

Mail-specific service terms explicitly take precedence over conflicting shared
company terms. Retain Apple's standard EULA for the installation licence. Verify
the final pages and in-app links before release; the agreed URLs do not establish
that these pages exist or have been approved.

## Existing privacy and authorization decisions

The [privacy requirements](privacy-and-sync.md),
[account removal contract](../account-removal.md) and
[telemetry requirements](../telemetry.md) continue to apply. The age requirements
above additionally constrain availability of optional consent-based features;
existing encryption and account-removal boundaries remain in force.

[Google production authorization](../google-registration.md#production-authorization)
is recorded as owner-verified on 2026-10-28. Its future revalidation checklist is
not evidence of a newly outstanding approval.

## Readiness work and required evidence

### Native integration

- On iPhone and iPad, obtain Apple's managed
  [mail-client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.mail-client),
  configure the App ID and signing, and verify the entitlement in the distributed
  app. Register `mailto:` and implement incoming URL handling.
- On Mac, register `mailto:` and implement incoming URL handling and the supported
  [default-application selection](https://developer.apple.com/documentation/appkit/nsworkspace/setdefaultapplication%28at%3Atoopenurlswithscheme%3Acompletion%3A%29).
  The iOS managed entitlement is not the Mac default-handler mechanism.
- Reuse #854 for the existing native workflow scope. Qualify default selection
  and incoming links in packaged clients on iPhone, iPad and Mac, alongside the
  sharing, attachment, print and message-export journeys.
- Cover cold and warm launch, offline use, existing unsaved Drafts, locked or
  unavailable Profiles, changed sending identities, cancellation and relaunch.
  An incoming action must not expose another account's data or replace authored
  content without the existing Draft-save guards.
- New visible states follow the repository's
  [Figma approval and native design review](../agents/implementation-review.md#design-approval).

### Legal documents and operations

- Inventory actual processing before writing the app privacy notice: local mail
  and credentials, encrypted Private Sync, backend-readable operational data,
  provider signals, diagnostics, support and any enabled cloud assistance.
  Distinguish implemented processing from planned features. Encryption does not
  justify describing all data as anonymous or claiming that no data is collected.
- Establish applicable purposes and legal bases, retention and backup-deletion
  rules, service-provider contracts and transfers, request handling and incident
  procedures. Assess controller and processor roles for actual personal and work
  mail use rather than assigning one role to every activity.
- Write the app notices and terms in language understandable to the intended
  teenage audience. Disclose eligibility and the paid offering before purchase,
  including compatibility, purchased functionality, support and update promises,
  and applicable consumer remedies. Do not invent a lifetime-service promise or
  an arbitrary support cutoff.
- Reconcile the existing shared terms, app-specific documents, purchase listing
  and in-app presentation. Link the app privacy notice in App Store Connect and
  accessibly in the app, including before Product Sign-In.
- Qualify support requests from signed-out users and users missing encryption
  keys, guardian requests, verification failures, offline or interrupted deletion,
  and export of product-owned data. Respect the existing distinction between
  Product Account deletion and provider-mail deletion.
- Review the applicable requirements for each release territory, including teen
  protections and required guardian approvals for core access, consumer law,
  accessibility and software-security obligations. Record classifications,
  applicable exemptions and remaining actions; hold territories whose required
  conditions are unmet. The absence of an optional parental-consent flow does not
  waive required purchase or core-access approvals.

### Store, provider and distribution readiness

- Complete the applicable Apple agreements, banking and tax information, trader
  verification, age rating, privacy disclosures and review information. Set the
  launch price and confirm universal-purchase and eligible Family Sharing
  behavior against the actual App Store configuration and agreements.
- Audit distribution artifacts for privacy manifests, SDK declarations,
  required-reason APIs, permission descriptions, sandboxing and third-party
  licence notices. Evaluate shipped cryptography and the applicable export and
  territory-specific declarations; do not infer an exemption from TLS alone.
- Reconcile provider data-use disclosures with shipped scopes and processing.
  Preserve the recorded Google approval; revalidate changes when required.
- Test app age eligibility independently of App Store purchase approval. Cover
  declined, missing and insufficient platform information, shared devices,
  Product Account changes, upgrades, offline use and late responses. Existing
  optional-feature consent does not itself supply missing age eligibility.

### Reference requirements

- [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Universal purchase](https://developer.apple.com/help/glossary/universal-purchase)
- [Apple age assurance](https://developer.apple.com/support/age-assurance/)
- [App privacy disclosures](https://developer.apple.com/app-store/app-privacy-details/)
- [Export compliance](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance/)
- [EU trader requirements](https://developer.apple.com/help/app-store-connect/manage-compliance-information/manage-european-union-digital-services-act-trader-requirements/)
- [GDPR](https://eur-lex.europa.eu/eli/reg/2016/679/oj/eng)
- [Czech consumer guidance for digital content and services](https://coi.gov.cz/faq/smlouvy-o-poskytovani-digitalniho-obsahu-ci-sluzby/)

## Delivery boundaries

After shared-understanding confirmation, split implementation and qualification
into reviewable issues, reusing existing native, provider, telemetry and launch
work. Track uncompleted account-owner, legal, tax, hosting and real-device actions
as prerequisites with evidence, not as completed work. App Store submission,
published notices and code tests alone do not establish worldwide legal clearance.
