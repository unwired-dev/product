---
status: accepted
---

# Deliver Scheduled Sends from any trusted device or the provider

## Context

[ADR 0062](0062-keep-queued-delivery-on-its-originating-device.md) keeps queued
delivery on the device where the person pressed Send, and the replacement applied
that rule to Scheduled Send. A scheduled message can wait hours or days, so tying
it to one device that may be closed, offline or lost makes it unreliable. On
6 Nov 2026 the product owner approved the
[#659 Scheduled messages decisions](https://github.com/unwired-dev/product/issues/659#issuecomment-6692821318).
Issues [#1262](https://github.com/unwired-dev/product/issues/1262),
[#1263](https://github.com/unwired-dev/product/issues/1263) and
[#1264](https://github.com/unwired-dev/product/issues/1264) own the acceptance
criteria.

## Decision

A Scheduled Send belongs to the Mail Profile, not to the device that created it.
Any Trusted Device of the Profile can open, edit, reschedule, cancel and Send Now
a Scheduled Send. Every change is revision-fenced, so there is only ever one
current delivery commitment.

**Provider scheduling.** When the selected Mailbox Connection's API supports
native scheduled delivery, the provider schedules the message. Microsoft Graph
deferred delivery (Outlook) and JMAP (`sendAt` / SMTP `FUTURERELEASE`) qualify.
The Gmail API, iCloud and plain IMAP/SMTP do not; those connections use device
claiming. A trusted device hands the message to the provider schedule and
records that handoff in Private Sync.

- Opening a provider-scheduled message pauses the provider schedule. Closing it
  resumes or replaces that schedule with the current content and due instant.
- If the provider cannot be reached on close, the message falls back to device
  claiming and shows "Not scheduled with Outlook yet". Device fallback may send
  only after the provider schedule is confirmed paused or cancelled; an
  unconfirmed pause is an unknown outcome, never permission to send.
- Cancel Schedule and Mailbox Connection removal cancel the provider schedule.

**Device claiming.** Without a provider schedule, the first available Trusted
Device that is due and eligible claims the item through Private Sync's
content-free Convex coordination, then delivers it. The claim reuses the
[ADR 0046](0046-coordinate-private-scheduled-send-on-trusted-devices.md)
**Scheduled Send Claim** and **Scheduled Delivery Authorization**:

- Exactly one revision-bound claim can advance an item toward provider handoff.
  The backend rejects early, stale-revision and duplicate claims. Editing,
  rescheduling, cancellation and an open editing session race atomically with
  pre-handoff claims. A device that loses the claim does not send.
- Provider handoff writes a durable fence that no other device may cross until
  the outcome is reconciled. An expired pre-handoff claim may pass to another
  device; a claim past that fence never does.
- Immediately before handoff, the claimant revalidates its Trusted Device
  Credential, Scheduled Delivery Authorization, Mailbox Authorization, the
  selected Mailbox Connection and the current revision.
- A message open at its due time waits until it is closed. The ordinary Undo
  Send Window applies after the claim and before handoff.

**Unknown outcomes.** When any device cannot tell whether the provider accepted
a send, it shows "Sending status unknown" with Check Sent and Send Now. Neither
that device nor another one resubmits automatically, preserving
[ADR 0016](0016-durable-outbox-delivery-attempts.md).

**Retained boundaries.** Admission still requires the complete encrypted payload
and assets in Private Sync and durable Draft retirement; it fails closed while
offline or uncertain. Delivery is best effort at or after the due instant, and an
item more than 24 hours late needs attention instead of sending. A Scheduled Send
never silently changes its Mailbox Connection or Sending Identity. Provider
credentials and readable mail stay on trusted devices; the backend holds only the
content-free coordination record that ADR 0046 permits. A provider schedule
gives that provider the readable message before its due time, as provider-hosted
Drafts already do under
[ADR 0074](0074-use-provider-hosted-drafts-for-cross-client-editing.md).

## Supersession and retained scope

This decision supersedes, for Scheduled Send only, the originating-device
delivery ownership in ADR 0062 and the replacement-scope note in ADR 0046 that
kept it. It also supersedes ADR 0046's choice of a product-owned Outbox item
rather than a provider-native timer. Immediate Send, the Undo Send Window and
every other queued Outbox delivery stay on their originating device under
ADR 0062. ADR 0062's atomic content-free send admission and uncertain-outcome
safety apply to both delivery paths.

## Consequences

- Scheduled delivery no longer depends on one device staying on, online and
  authorized, at the cost of a cross-device claim protocol and a provider
  schedule that must be paused, resumed and reconciled.
- Every provider adapter must report whether it supports native scheduled
  delivery; the default is device claiming.
- Microsoft and JMAP connections hold scheduled content with the provider until
  delivery, so another mail client of that account may see or change it.

## Status and qualification

This is an owner-approved target, not an implementation or qualification claim.
The launch specification and the issues above own the required journeys and
provider evidence.
