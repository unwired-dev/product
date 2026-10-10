# Assistance: architecture notes

Reviewer-only companion to [docs/product/assistance.md](../../product/assistance.md).
Read under the [implementation and review workflow](../../agents/implementation-review.md).
Extracted passages retain their source scope; prototype details do not establish
replacement requirements or release qualification.

## Scope

Explicit on-device assistance remains part of the replacement. Planned Catch Up
adds Background Message Summaries as its only background-generation exception,
gated by device-local, default-off Mail Assistance Enablement and retained only
in the encrypted local cache under ADR 0068. Profile-specific
terms also describe prototype or follow-up behavior; platform and launch scope
come from the accepted replacement decisions.

## Decisions and scope

- [Accepted replacement scope](../../adr/0059-replace-the-client-for-a-shared-cross-platform-product.md)
- [Keep Mail Assistance on device and input-bound](../../adr/0052-keep-mail-assistance-on-device-and-input-bound.md)
- [Keep Mail Assistance enablement device-local](../../adr/0053-keep-mail-assistance-enablement-device-local.md)
- [Allow device-local Background Message Summaries](../../adr/0068-allow-device-local-background-message-summaries.md)

[The documentation index](../../README.md) explains ADR precedence and separates
current replacement work from prototype maintenance and historical plans.
