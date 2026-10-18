# Opt-in analytics and error reporting

Status: accepted requirements from the 2026-10-12 interview, recorded in
[issue #913](https://github.com/unwired-dev/product/issues/913). This document
does not establish an installed SDK, a provisioned service, passing native
qualification, or an enabled telemetry feature. Integration is separate work.
The approved error-reporting implementation slice is tracked in
[issue #1049](https://github.com/unwired-dev/product/issues/1049), following the
2026-10-18 interview below. Product analytics remains separate future work.
The reviewer-owned provider decision is recorded in
[ADR 0071](adr/0071-use-opt-in-posthog-eu-telemetry-on-the-free-plan.md).

[Vocabulary](domain/privacy-and-sync.md) · [Privacy requirements](product/privacy-and-sync.md)

## Scope

The maintained iPhone, iPad and Mac clients will support product analytics for
onboarding conversion, feature adoption and returning **Analytics Installations**,
plus reporting of JavaScript errors and native crashes. Backend failure reporting
is also in scope, with the coverage limits below. General debug-log collection,
session replay and automatic interaction capture are outside this scope.

The selected initial service is PostHog Cloud in the EU region on its Free plan.
No paid telemetry subscription, Convex upgrade for telemetry, automatic overage,
or self-hosted service is authorized by this decision.

## Approved error-reporting slice

The implementation covers unhandled JavaScript errors, native crashes and
explicitly classified failures of app operations, including sending,
synchronization and sign-in. Expected offline conditions and user cancellation
are excluded. TestFlight and production use the same consent rules, with test
reports distinguishable from production. Ordinary development builds remain
disconnected except during deliberate qualification.

Original exception types, messages, stacks and cause chains may be reported where
safe, together with a bounded recent history of navigation, operation steps,
retries, timings and safe status codes. Breadcrumbs are attached to failures;
they are not uploaded independently or used to enable product analytics.
The sensitive-data exclusions below still apply inside every error and
breadcrumb. Remove sensitive values; when a message cannot safely be retained,
omit it and retain the safe stack and failure code.

Expose App Error Reporting Consent from privacy controls on Welcome, before
Product Sign-In, and in Settings. Do not add an onboarding prompt. Fresh and
upgraded installations start with reporting off until explicitly enabled.
Turning reporting off, signing out or deleting a Product Account stops collection
and transmission and discards pending reports, including native crash reports
and delayed uploads after relaunch. Opted-in reports may wait in a bounded local
queue for at most 24 hours; expired reports are discarded. Reporting failures
must never prevent mail use.

Error reports use their own random installation identifier, independent of
Product Analytics Consent, Product Accounts, Trusted Devices and mailboxes.
A minimal pseudonymous installation profile at PostHog is permitted where needed
for grouping and verified deletion; it must not add account or cross-device
linkage.

Settings provides a separate **Delete my error reports** action for this
installation's uploaded reports. Deletion turns reporting off and purges pending
reports. It remains pending until remote completion is verified; offline and
failed requests remain pending or retryable, without claiming success.
Reporting stays off after completion until explicitly enabled again.
The installation's deletion credential survives sign-out and Product Account
deletion so those reports can still be removed without signing in. There is no
account-linked recovery or separate recovery code. Explain that reinstalling or
wiping the device may remove the ability to delete earlier reports.

Native capture first passes the
[consent-revocation feasibility gate](https://github.com/unwired-dev/product/issues/1050)
on iPhone, iPad and Mac. If a supported approach cannot meet these requirements,
leave native capture disabled and report it blocked rather than weakening consent
or claiming qualification. New Welcome, reporting and deletion states require
Figma approval before client UI implementation.

## Consent and identity

- **Product Analytics Consent** and **App Error Reporting Consent** are separate
  **Device-Local Preferences**, both off until the person enables them.
- Enabling one does not enable the other. Neither choice is propagated through
  **Private Sync** or inferred from Product Sign-In on another device.
- Disabled consent must prevent collection and transmission for that channel,
  including delayed uploads after a restart. Previously uploaded data requires
  a separate, explicit deletion mechanism; disabling a switch is not proof of
  remote deletion.
- Product analytics uses a random installation identifier, without linking it
  to a **Product Account**, **Trusted Device**, mailbox or another installation.
  One person using iPhone and Mac counts as two installations. This identity is
  pseudonymous, not proof that the data is anonymous.
- Opted-out installations are absent from the corresponding usage and crash
  statistics. Dashboards must not describe participating installations as all
  users or interpret installation retention as cross-device person retention.
- Minimal backend service-health reporting is separate from these app opt-ins
  and carries no user identity.

## Permitted data

Only explicitly allowlisted event names and fields may leave the app or backend.
The implementation must define that inventory before collection is enabled.
Existing [diagnostic export restrictions](product/privacy-and-sync.md#device-local-data-and-preference-conflicts)
remain applicable; this decision does not authorize raw failure dumps.

Exclude mailbox addresses and identifiers, message content and subjects,
recipients, search text, provider credentials, Categories, Private Sync plaintext,
and other user-authored text. Error messages, nested causes, breadcrumbs,
console output, network URLs and native attachments are not implicitly safe.
Automatic interaction capture and session replay remain disabled.
The approved error-reporting slice permits original error details and explicit
breadcrumbs only within these exclusions; it does not permit unchecked SDK
payloads, console capture or general debug-log collection.

Application version, platform, predefined operation or error codes and sanitized
stack information are candidates for the allowlist, not permission to forward an
SDK's default payload unchecked. Any SDK-added identifiers, IP-derived enrichment
or contextual data must be evaluated alongside explicit application properties.

## Free-plan operation and backend coverage

Vendor facts below were checked on 2026-10-12 and must be rechecked when integrating:

- PostHog Free includes one project, one million analytics events and 100,000
  exceptions per month. It does not require a payment card. Events above the
  free allowance are permanently dropped, not queued for the following month.
  Keep collection within that allowance; missing telemetry must not prevent mail
  use. [PostHog pricing](https://posthog.com/pricing)
- The free event retention window is one year. This is not a guaranteed deletion
  deadline, and a shorter automatic retention period cannot be configured.
  The accepted policy includes an explicit deletion mechanism; its identity,
  authorization and completion behavior must be specified and verified before
  rollout. [Retention](https://posthog.com/docs/data/events-retention),
  [deletion](https://posthog.com/docs/privacy/data-storage#data-deletion)
- Convex automatic exception reporting and log streaming require Pro. Changing
  the receiving service does not remove that requirement.
  [Exception reporting](https://docs.convex.dev/production/integrations/exception-reporting),
  [log streaming](https://docs.convex.dev/production/integrations/log-streams)
- Custom reporting may capture selected catchable backend failures and safe
  client-observed failures, subject to the relevant app consent. This is partial
  coverage: server-only failures, runtime termination, timeouts and unavailable
  clients can leave gaps. Backend stacks are not necessarily available to the
  client. Convex's dashboard logs remain part of troubleshooting; this decision
  does not authorize adding sensitive data to those logs.
- Reporting consumes existing backend execution allowances. Do not bypass a
  free limit with a paid upgrade or claim complete centralized backend coverage.
  [Convex limits](https://docs.convex.dev/production/state/limits)

## Qualification before enabling telemetry

Implementation must demonstrate the following on the maintained host versions:

1. Signed release-build JavaScript error and native crash reporting on iPhone,
   iPad and native Mac, with readable source-mapped and symbolicated reports.
   A vendor's platform-support statement is not project qualification.
2. Consent remains off on a fresh installation; each channel works independently;
   revocation also prevents queued uploads, including native crash reports on
   the next launch and events collected while offline.
3. Outgoing JavaScript, native and backend payloads contain only the approved
   fields. Inject synthetic sensitive content into error causes, paths, URLs,
   console output and native context to check for leakage before transmission.
4. Product analytics identifiers do not link Product Accounts or devices. Define
   identifier lifecycle and the minimum identity needed for error reporting
   without silently reusing the analytics identifier across channels.
5. Explicit deletion has a verified path for installation-scoped data. Specify
   how requests are authorized and completed, including sign-out, account
   deletion and reinstall limitations, without adding account linkage implicitly.
6. Document which backend failures reach PostHog and which require Convex logs;
   verify this with failing operations rather than a successful capture call.
7. Telemetry outages, offline operation and exhausted free quotas do not block
   mail workflows. Test data is distinguishable from production measurements.

No integration or native qualification was performed as part of this decision.
SDK selection, the event inventory, deletion flow, consent-control design and
failure-coverage checks remain implementation work under the repository's normal
design and review workflow.
