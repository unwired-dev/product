---
status: accepted
---

# Allow device-local Background Message Summaries

Amended on 2026-10-10 following the product owner's answers on
[PR #814](https://github.com/unwired-dev/product/pull/814): summaries share the
Bounded Encrypted Body Cache budget and lifetime, as specified below.

## Context

[Catch Up #807](https://github.com/unwired-dev/product/issues/807) presents the
Inbox as message bubbles, each showing a summary or a preview. Requiring a
separate generation action for each message would prevent summaries from being
ready while the person triages mail. The user explicitly authorized background
summaries and their device-local storage; [#808](https://github.com/unwired-dev/product/issues/808)
records this decision.

## Decision

Allow the [Background Message Summary](../domain/assistance.md) as the sole
exception to explicitly requested Mail Assistance. Generate it with Apple's
on-device system language model for one already-local message's new content,
removing quoted history first. Keep the input bounded and treat mail as untrusted
data. Do not fetch missing bodies, attachments, Inline Images or Remote Message
Content for inference, and do not add model tools or a cloud fallback.

Generation requires [Mail Assistance Enablement](../domain/assistance.md) on the
same device. The preference remains device-local, defaults off independently on
every device, never synchronizes and is cleared with Product Account removal.
The existing Product Account and Mail Profile ownership boundaries remain; this
decision does not add advanced Profiles to replacement launch scope. The
pre-implementation decision panel selected this gate unanimously (3–0:
`claude-fable-5-1`, `gpt-6.1-sol`, `gpt-6-astra`).

Store the result only beside its message body in the device's
[Bounded Encrypted Body Cache](../product/privacy-and-sync.md). Summary bytes
count toward that cache's existing device-wide limit. Remove the summary when
its body is evicted, the cache is cleared, or the message is deleted. Never
synchronize it, even as Product Sync ciphertext, send it to any server, or write
it into provider mail or Drafts.
The model binding returns a value; the local cache owns persistence, preserving
the model's independence from storage and network access.

Retain owner and input-revision checks before displaying or storing a result.
Disabling assistance or losing access to its owning account or Profile cancels
active work and rejects late results. Changed source content invalidates its
summary. Catch Up shows the message preview when assistance is disabled or
unavailable; ordinary mail remains usable. Foreground passes and OS-granted
background execution follow the [Catch Up requirements](../catch-up.md#summaries),
without an independently running Mac helper or a promise of iOS background time.

## Scope and supersession

For Background Message Summaries only, this decision supersedes the
explicit-invocation clauses of
[ADR 0052: Keep Mail Assistance on device and input-bound](0052-keep-mail-assistance-on-device-and-input-bound.md),
the clauses in
[ADR 0053: Keep Mail Assistance enablement device-local](0053-keep-mail-assistance-enablement-device-local.md)
that enablement never starts inference and surfaces must wait for an explicit
action, and the explicitly invoked launch-assistance restriction in
[ADR 0059: Replace the client for a shared cross-platform product](0059-replace-the-client-for-a-shared-cross-platform-product.md).

Explicit Understanding Assistance remains ephemeral and separately requested.
Compose, Response and Translation Assistance keep their explicit invocation and
acceptance rules. This exception does not authorize background Thread analysis,
automatic replies or edits, cloud inference, or synchronized generated text.
The version-27 deployment floors and platform availability checks remain.

## Consequences

- Each opted-in device generates its own summaries; devices may show different
  text or a preview while no summary is available.
- Background execution and model availability are best effort. Summaries cannot
  become a prerequisite for reading or acting on mail.
- Catch Up remains planned, with mobile first and macOS following. Stand-in
  summaries with real synced Gmail exercise the product interface; they do not
  qualify Apple's model or background execution on devices.
- Implementation must verify encrypted local retention within the body-cache
  limit and deletion on body eviction, cache clearing and message deletion,
  absence of network or Product Sync output, enablement, cancellation and
  stale-result handling. Native iOS, iPadOS and macOS 27 model and
  background-execution evidence remains required before release.
