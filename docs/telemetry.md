# Opt-in analytics and error reporting

Status: accepted requirements from the 2026-10-12 interview, recorded in
[issue #913](https://github.com/unwired-dev/product/issues/913). This document
does not establish a provisioned service or passing release qualification.
The implementation below remains subject to the explicit rollout checks.
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

At process startup, a synchronous native snapshot seeds the shared reporting
policy before application modules run. The shared schema validates that snapshot;
missing, locked, unavailable or malformed state leaves collection off. Hooks are
installed before registration side effects, delivery, freshness, routing and
windows evaluate. The ordinary asynchronous read still reconciles state and
starts retries. No raw errors are buffered while consent is unknown. Failures
inside the minimal bootstrap's own dependencies remain outside its protection;
release startup behavior still requires platform qualification.

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
An installation that has never enabled reporting completes deletion locally:
there is no reporting capability to register or withdraw remotely.

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

The original provider decision performed no integration. Issue #1049 adds the
implementation below; protected vendor and signed-device checks remain required
before release. Partial local feasibility evidence does not qualify all hosts.

## Error-reporting implementation

Welcome exposes Privacy & Data before sign-in. Settings exposes the same
installation-local reporting switch and a separate Delete my error reports action.
Reporting defaults off, including upgrades. Product Analytics Consent is not
implemented by this slice. The approved iPhone, iPad and Mac Light/Dark states
are [iPhone](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=386-138848),
[iPad](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=386-54772) and
[Mac](https://www.figma.com/design/d1mHEaUNmnF7YUw6QwIs0T?node-id=386-133080).

The shared store owns consent, safe projection, the bounded queue and deletion
state. The reviewer-owned [architecture companion](architecture/telemetry.md)
records its implementation boundaries. The native host owns an independent Keychain installation UUID and
256-bit deletion credential, generation checks, native collection and purge.
Neither identity nor credential is exposed to screens or linked to Product
Accounts. Revocation cancels native capture requests and preserves a durable
withdrawal marker until the receiver acknowledges it; restart retries cleanup.
Sign-out and account removal withdraw consent before clearing account data.
Deletion preserves the credential through those operations, polls verified
remote completion and keeps reporting off. Re-enabling after completed deletion
creates a new reporting identity; the deleted identity cannot be reopened.
A deletion request remains pending across interruption or a purge failure, with
reporting off on relaunch. A storage failure still turns reporting off and cannot
be reported as completed deletion.

The wire inventory is defined by the contracts' errorReportingSchema entry point:

| Field                    | Permitted value                                                                                                                                 |
| ------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| Report identity and time | Random report UUID, creation timestamp; no mail or account identity                                                                             |
| Failure                  | Predefined code and exception name; only exact approved constant messages                                                                       |
| Stack                    | JavaScript bundle line/column, or native instruction address, image address and UUID; no paths, URLs or function text                           |
| Causes                   | Up to eight safe exception names and approved messages                                                                                          |
| Breadcrumbs              | Last 50 predefined navigation/operation stages, optional bounded elapsed milliseconds and HTTP status                                           |
| Build                    | Fixed public app namespace `dev.unwired.mail`, platform, numeric app version, build and OS version, production/TestFlight/qualification channel |

JavaScript stacks retain the innermost 64 matching bundle frames and send them
with the outermost retained call first and the throw site last, following
[PostHog wire order](https://github.com/PostHog/posthog-go/blob/main/error_tracking_stack_trace.go).
Native stacks retain the final 64 admitted frames in the pinned SDK's existing
wire order, so long stacks retain the crash site without forwarding SDK text.

Unknown messages are omitted rather than attempting to scrub arbitrary text.
JS global exceptions and exceptions surfaced through React Native's explicit
exception path, plus classified sign-in, sync and send transport failures, use
the same projection. Release Hermes promise-rejection coverage remains a
qualification check: no additional tracker is enabled until its consent and
purge behavior is demonstrated. Expected offline and
cancelled operations are excluded. Resolved provider HTTP failures and Convex
error envelopes are classified without retaining their response text or changing
the mail operation's result. Legacy native `unavailable` rejections are omitted
from operation reporting because they can mean a proven-unsent offline request;
global unexpected exceptions still use the normal projection. Known offline deletion errors show the offline state;
server and invalid-response failures show the retryable failed state. No console dumps, attachments, user text,
autocapture, session replay or independent breadcrumb upload is enabled. Queues
are bounded and reports expire after 24 hours. Loss of diagnostics is acceptable;
reporting failure must not change a mail operation's result.

The receiver exposes fixed POST /api/error-reporting/{enable,capture,revoke,delete,status}
capability endpoints on the existing Convex HTTP site. It rejects unknown fields,
invalid credentials, stale generations, oversized batches and expired reports.
Credentials are hashed at rest. Remote deletion waits for admitted deliveries and verifies vendor completion,
including when the app closes. An absent PostHog profile or an accepted deletion
request alone is not completion. An interrupted delivery whose outcome cannot be
settled leaves deletion pending for operator investigation.

Selected rejected or timed-out APNs service operations report fixed identity-free
backend health fields, independently of app consent. Atomic durable admission
permits the first failure immediately, then at most one health attempt per hour
across the deployment before scheduling a vendor action. Failed attempts consume
the same interval. This samples outage health with at most 744 attempts in a
31-day month; it does not reserve or qualify the project's free quota. Other backend failures,
termination and Convex log coverage remain partial. App-originated failures
always require installation consent.

### Configuration and rollout

Configure POSTHOG_PROJECT_KEY, POSTHOG_PROJECT_ID and POSTHOG_PERSON_API_KEY
only in the Convex deployment. Restrict the personal key to this project and
person read/write access. The receiver fixes ingestion to eu.i.posthog.com and
administration to eu.posthog.com. No vendor key or deletion authority belongs in
an app bundle. Missing backend configuration fails closed. Provision only the
free EU project without a card or automatic paid overages, and verify free-limit
behavior before release.

Both hosts use their existing UNWIRED_CONVEX_URL. Normal debug and mock builds
are disconnected. For an explicit local qualification build, set
UNWIRED_ERROR_REPORTING_QUALIFICATION=1 and
UNWIRED_ERROR_REPORTING_CHANNEL=qualification when generating the host. Release
and TestFlight use their corresponding channel and the same default-off consent.
UNWIRED_NATIVE_ERROR_REPORTING_QUALIFIED defaults to 0; keep it there until the
per-platform checks in #1050 pass. No Sentry service DSN is configured.

Sentry Cocoa 9.30.2 is used solely as a disconnected local native collector.
Every SDK request must remain blocked; only the approved projection may reach
PostHog through the application receiver. Revocation closes the collector and
purges its raw cache and projection queue. PostHog Swift's stock native collector
failed the local opt-out/relaunch probe and is not integrated.

Local macOS 27 probes exercised fresh-off, opt-in, pending-report purge,
revoke/crash and off/on relaunch without resurrection using the disconnected
collector. This is feasibility evidence only. Signed iPhone, iPad and Mac app
crashes, complete consent races, native-to-receiver forwarding, source-map and
native-symbol readability, 24-hour expiry, live PostHog deletion and quota
behavior remain protected release checks under #1050. A vendor login was not
available in this implementation session; deterministic receiver tests do not
stand in for those checks.

### Release symbols

Both maintained hosts ship Hermes. Prepare artifacts from the same signed archive,
using its final bytecode and composed Hermes map, its executable and its matching
dSYM. Plain Metro maps are refused. This command performs local checks only:

```sh
node scripts/reporting-artifacts.mjs --platform ios --version 1.0.0 \
  --build 202610181230 --bundle /archive/App.app/main.jsbundle \
  --map /same-build/composed.map --binary /archive/App.app/App \
  --dsym /archive/App.app.dSYM --output /new/reporting-ios-202610181230
```

Use `--platform macos` and the Mac executable under Contents/MacOS for Mac.
The output manifest records hashes, release coordinates, native UUIDs and exact
EU upload argument arrays. Its canonical app:///<platform>/<version>/<build>/index.bundle
is the chunk_id on both the map and the receiver's Hermes frames. The archive's
CFBundleIdentifier must be the approved public namespace `dev.unwired.mail`. It
becomes `--release-name` and the receiver's `$app_namespace`; the archive version
and build become `--release-version` / `$app_version` and `--build` / `$app_build`.
Both Hermes and dSYM upload commands use those same coordinates. Unknown app
namespaces are refused rather than forwarded as arbitrary metadata. Do not reuse
release coordinates for different bytecode. The artifact check confirms the map
format and native UUID match; actual JS mapping against that bytecode remains a
protected release check. The tool never invokes vendor commands automatically.

Use PostHog CLI 0.18.10 from revision
e519ba6304903b31e5e3d74c6d1a5fe9a96c745e. Published CLI binaries contain their
own telemetry, so build the pinned source in Release with POSTHOG_API_TOKEN absent
and a fresh target directory. This source-vetted recipe has not been executed in
the implementation session:

```sh
cli_source=$(mktemp -d)/posthog
git clone --filter=blob:none --sparse --no-checkout https://github.com/PostHog/posthog.git "$cli_source"
git -C "$cli_source" sparse-checkout set cli
git -C "$cli_source" checkout --detach e519ba6304903b31e5e3d74c6d1a5fe9a96c745e
env -u POSTHOG_API_TOKEN CARGO_TARGET_DIR="$cli_source/cli-target" \
  cargo build --release --locked --manifest-path "$cli_source/cli/Cargo.toml"
"$cli_source/cli-target/release/posthog-cli" --version
```

The pinned [build script](https://github.com/PostHog/posthog/blob/e519ba6304903b31e5e3d74c6d1a5fe9a96c745e/cli/build.rs)
and [invocation context](https://github.com/PostHog/posthog/blob/e519ba6304903b31e5e3d74c6d1a5fe9a96c745e/cli/src/invocation_context.rs)
control that separate CLI telemetry. Verify version 0.18.10, then use that binary
for the manifest's upload commands. Supply POSTHOG_CLI_API_KEY with
error_tracking:write access, POSTHOG_CLI_PROJECT_ID and
POSTHOG_CLI_HOST=https://eu.posthog.com only in the protected upload environment.
Keep these credentials out of app bundles. Do not force replacement of a
conflicting release's symbols. Confirm a synthetic JS error and native crash
resolve to the expected source before rollout.
