# Private Cloud Mail Assistance

This document records confirmed requirements for a planned feature. It is not
implementation or release evidence. The maintained
clients currently provide [on-device summaries](../message-summaries.md) and
[Draft rewrites and reply suggestions](../draft-assistance.md).

[Vocabulary](../domain/assistance.md) · [Current assistance requirements](assistance.md)

The reviewer-owned [ADR 0075](../adr/0075-prefer-private-cloud-compute-for-separately-authorized-mail-assistance.md)
records this accepted decision and its scoped amendments.

Delivery is tracked in [#1451](https://github.com/unwired-dev/product/issues/1451).

## Confirmed direction

- Private Cloud Mail Assistance uses Apple's Private Cloud Compute, with a
  separate, default-off opt-in for each device and Mail Profile of a Product
  Account. Existing Mail Assistance consent does not authorize PCC processing.
- Mail Assistance Enablement remains required. When both choices are enabled,
  supported operations prefer PCC over the on-device model.
- The first scope is explicitly requested message summaries, reply suggestions
  and rewrites. Richer Thread understanding follows. Background Catch Up
  summaries, categorization and Mail Commitment Suggestions are separate scope
  decisions. Translation continues to use Apple Translation in this initial scope.
- PCC context may extend beyond the existing on-device operation inputs. Data
  types are not excluded merely because processing occurs in PCC. The intent is
  to allow all relevant context for the requested task within the feature scope
  below, using supported formats and bounded processing.
- When PCC is offline, unavailable or quota-exhausted, an operation may fall back
  to the local model only if it can complete the same operation. The person is
  told when local inference is used. A request that cannot fit the local model
  must explain the limitation rather than silently omit context. A refusal must
  not trigger a retry through another model.
- Generated Draft changes continue to require explicit review and acceptance.
  Acceptance remains undoable, and assistance never sends mail automatically.

## Context retrieval and operation behavior

- An explicit Summarize or Suggest reply request may automatically download
  missing messages and attachments from the current Thread. Searching other
  Threads requires an explicitly broader request, such as finding a previous
  agreement with the same customer.
- Context stays within the active Mail Profile. Enabling PCC for several
  Profiles never authorizes implicit use of another Profile's mail. Crossing
  Profiles requires a deliberate choice.
- Rewrite preserves the author's facts and intent. Adding facts from
  correspondence or attachments belongs to an explicitly requested reply or
  drafting action.
- The existing Summarize action continues to summarize the opened message.
  Thread context may resolve references without changing that target. Summarize
  Thread is a separately named action in a later stage.
- Summaries and reply previews identify supporting messages and attachments,
  disclose unreadable or omitted material, and flag uncertain claims. Source
  references appear in the review interface.

## Initial and follow-up sources

The first PCC release uses mail, headers, PDFs, images and text attachments
within the active Mail Profile. Contacts, Calendar, mailbox-wide research and
cross-Profile assistance are separate follow-up features. Permission to use
broader context in principle does not make these integrations part of the
initial release.

The follow-ups are tracked separately:

- [Contacts context](https://github.com/unwired-dev/product/issues/1453)
- [Calendar context](https://github.com/unwired-dev/product/issues/1454)
- [Mailbox-wide research](https://github.com/unwired-dev/product/issues/1455)
- [Deliberate cross-Profile assistance](https://github.com/unwired-dev/product/issues/1456)
- [The separately named Summarize Thread action](https://github.com/unwired-dev/product/issues/1457)
- [Evaluation of background PCC processing](https://github.com/unwired-dev/product/issues/1458)

## Attachment support and large Threads

- The first version supports understanding PDFs, images and text files. It must
  clearly identify attachments it cannot read. Other document formats may follow.
- A Thread that exceeds PCC's context capacity is processed in bounded stages
  with source references, progress and cancellation. This may consume several
  requests. If the bounded process cannot cover the requested material, the
  result explains what is missing and asks the person to narrow the request.
  It must never silently drop older messages or attachments.

## Retention and cancellation

- Generated previews and temporary extracted context remain ephemeral. Neither
  is synchronized or included in content logs. Downloaded mail follows the
  normal encrypted cache rules; explicit acceptance stores generated Draft
  content through the existing Draft behavior.
- Disabling PCC cancels its active work and discards its previews. Subsequent
  requests may use on-device assistance. Existing cancellation and stale-result
  rejection rules also apply to Profile lock, account removal and changed source
  content.

## Background feature scope

Catch Up summaries, categorization and Mail Commitment Suggestions retain their
existing on-device requirements for the first PCC release. Cloud processing for
those features requires a separate evaluation of scope, consent and quota use.

## Scope of the existing requirements

The existing on-device-only requirements remain the current implementation
contract. The direction above adds a separately authorized mode; it does not
retroactively authorize cloud processing for existing opt-ins or establish that
planned background features have shipped.

Existing input limits remain binding for the on-device mode. PCC follows the
context-selection and retrieval scope above. Source changes must continue to
invalidate affected requests and previews in either mode.

## Release independence

PCC is an optional enhancement. Missing entitlement approval or device
availability must not block core mail or existing on-device assistance. PCC
ships only after entitlement approval and its real-device checks pass.

## Delivery and acceptance

Deliver the complete initial scope on iPhone, iPad and Mac. Core mail and the
existing on-device mode remain independently releasable throughout this work.

1. Verify Apple developer eligibility and obtain the managed entitlement. Prove
   native PCC access, text and image prompting, supported languages, PDF text
   extraction, availability, quota reporting and cancellation on supported hosts.
   Do not assume arbitrary binary attachments are supported.
2. Design the PCC opt-in, processing disclosure, source review, progress,
   unavailable and quota states in Figma. Follow the repository's design approval
   workflow before implementing the affected UI.
3. Add the separate device/account/Profile consent and PCC preference to the
   existing assistance flow. Reuse its lifecycle behavior. Exercise ordinary
   generation, compatible local fallback, refusal, cancellation and late-result
   rejection before expanding context.
4. Complete Thread retrieval, PDF/image/text processing, bounded staged
   generation and source-linked reviews for the initial operations. Preserve the
   opened-message summary target, meaning-preserving Rewrite, explicit acceptance
   and Undo. Other Threads and Profiles remain outside implicit retrieval.
5. Qualify the complete scope on real iPhone, iPad and Mac hardware before
   releasing PCC. Compare local and PCC quality, source-language preservation,
   factual fidelity, source references, coverage, latency and observed request
   usage with a versioned synthetic mail and attachment corpus.

Integration and native journeys must cover consent migration and isolation,
Thread and attachment retrieval scope, unsupported and unreadable attachments,
multi-stage coverage, quota exhaustion, fallback compatibility, refusal,
cancellation during retrieval or generation, source changes, Profile lock,
account removal, explicit acceptance and Undo. Mocked outcomes remain distinct
from real PCC evidence. Tests must show that untrusted mail and attachments do
not become system instructions or authorize mail mutations.

Numeric processing budgets and reasoning settings are implementation details
to establish through evaluation within these requirements. Exact Apple quota
counts and arbitrary-file support must not be promised without platform evidence.

## External prerequisites

Apple's [PCC integration guide](https://developer.apple.com/documentation/foundationmodels/adding-server-side-intelligence-with-private-cloud-compute)
documents native Foundation Models sessions on OS 27 and later, Apple
Intelligence device eligibility, network requirements and daily usage limits.
Applications must handle model availability and quota exhaustion.

Apple's [access requirements](https://developer.apple.com/private-cloud-compute/)
include Small Business Program membership, the first-time download threshold
and approval for a managed entitlement. Eligibility and entitlement approval
are unverified for this product and remain delivery prerequisites.
The [managed-entitlement prerequisite](https://github.com/unwired-dev/product/issues/1452)
tracks the required human access work.
