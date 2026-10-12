---
status: accepted
---

# Use opt-in PostHog EU telemetry on the Free plan

## Context

The product owner completed the analytics and error-reporting interview on
2026-10-12. [Issue #913](https://github.com/unwired-dev/product/issues/913)
records the documentation scope and accepted requirements. The maintained
iPhone, iPad and native Mac clients need onboarding, feature-adoption and
installation-retention analytics, JavaScript error reporting and native crash
reporting. Backend failures also need visibility.

The constraints are managed EU hosting, a free tier, explicit allowlisted
payloads and no mailbox content or account linkage. Integration and service
provisioning are separate work. The complete observable requirements and
qualification gates belong in [the telemetry guide](../telemetry.md).

## Decision

Select PostHog Cloud EU on its Free plan as the initial provider for product
analytics and error tracking. Do not add Sentry alongside it now. One service
reduces the number of integrations, payload filters and deletion paths that
must enforce the same privacy policy. Paid telemetry, automatic overage,
Convex upgrades for telemetry and self-hosting are outside this decision.

Use separate device-local Product Analytics Consent and App Error Reporting
Consent, both off by default. Product analytics uses a random installation
identifier without Product Account, Trusted Device or cross-device linkage.
Minimal backend service-health reporting is separate from app consent and
carries no user identity. Preserve the explicit allowlist boundary in
[ADR 0046: Allowlist device-local diagnostics](0046-allowlist-local-diagnostics.md)
and the device-local preference boundary in
[ADR 0019](0019-sync-mail-workflow-preferences-not-device-state.md).
This permits selected opt-in telemetry, not arbitrary logs, raw failure dumps,
session replay or automatic interaction capture.

Accept partial centralized backend coverage and use Convex dashboard logs for
the remaining troubleshooting. Convex's automatic exception export and log
streams require Pro, whether the destination is PostHog or Sentry. Direct
third-party requests belong in actions; scheduling a reporter inside a mutation
that then fails rolls back the scheduling too. A custom integration therefore
cannot promise every server-only failure reaches PostHog.
[Exception reporting](https://docs.convex.dev/production/integrations/exception-reporting),
[log streams](https://docs.convex.dev/production/integrations/log-streams),
[actions](https://docs.convex.dev/functions/actions),
[mutation scheduling](https://docs.convex.dev/scheduling/scheduled-functions#scheduling-from-mutations).

Accept the Free plan's one-year event retention window without treating it as
a guaranteed automatic purge deadline. A shorter window is unavailable.
Explicit deletion remains required before rollout, with identity, authorization
and completion behavior still to be specified. Installation-scoped telemetry
does not become Product Account data merely to reuse account deletion.
[Retention](https://posthog.com/docs/data/events-retention),
[deletion tools](https://posthog.com/docs/privacy/data-storage#data-deletion).

## Evidence and consequences

Vendor facts were checked on 2026-10-12. PostHog Free provides one project,
one million analytics events and 100,000 exceptions per month without a payment
card. Collection above the free allowance is dropped. Telemetry loss is an
accepted consequence of the budget and must not block mail use.
[PostHog pricing](https://posthog.com/pricing).

PostHog reports native React Native macOS crash support in
`posthog-react-native` 4.56.0 and `@posthog/react-native-plugin` 2.2.0 or newer,
including a native SIGSEGV test on React Native macOS 0.81. This is vendor
evidence, not qualification of this repository's host versions or signed release
builds. [Vendor release confirmation](https://github.com/PostHog/posthog-js/issues/3827#issuecomment-5315981001).

Qualify JavaScript errors, native crashes, source maps and symbols independently
on each maintained host before enabling collection. If PostHog fails an actual
qualification gate, evaluate Sentry as an alternative error-reporting provider
under the same privacy and budget constraints; this decision does not authorize
a second service or relax the gates.

Opt-in measurements describe participating installations, not all users or
unique people across devices. Revocation, queued uploads, outgoing payload
filtering, identifier lifecycle, deletion, backend failure coverage and outage
behavior remain required implementation checks in the telemetry guide. This
record does not claim that an SDK is installed, a service is provisioned or any
telemetry qualification has passed.
