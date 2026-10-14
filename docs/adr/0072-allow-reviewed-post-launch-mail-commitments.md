---
status: accepted
---

# Allow reviewed post-launch Mail Commitments

## Context

On 2026-10-13 the product owner confirmed the complete
[Mail Commitments requirements](../product/mail-commitments.md), including
automatic on-device analysis and natural-language deadline recognition. The
feature follows the confirmed power-user launch. These accepted future choices
require scoped exceptions to explicit-only assistance, ephemeral previews and
connection-owned cleanup. This decision records that authorization, not a new
launch gate, implementation or qualification evidence.

## Decision

Permit automatic Mail Commitment Suggestions for eligible new received and sent
mail after default-off, device-local Mail Assistance Enablement, with a separate
device-local per-Profile scan switch. Historical analysis still requires an
explicit bounded request. Use bounded already-local message text as untrusted
input, with no model tools, missing-content fetch or cloud fallback. Keep the
model independent of persistence, provider access and network activity.

Persist minimal unaccepted suggestions encrypted only on the generating device,
with source links instead of copied message bodies. Profile Lock hides the queue
and cancels analysis without deleting these persisted proposals; Assistance Off
clears them, while Scan Off retains them. Owner and source-revision fences still
reject late results, and known source changes or deletion retire proposals.

Only explicit review creates or updates an authored commitment. Accepted records
and minimal review decisions synchronize end-to-end encrypted; unaccepted model
outputs never synchronize. Existing native key custody and account/device trust
requirements apply. Independent edits merge and competing edits remain available
for review. Stale work cannot silently reopen accepted records. Delete wins over
concurrent or stale edits, scans and retries: they cannot resurrect the deleted
record or preserve its deleted content as a conflict copy. Delete removes authored
content while retaining only the minimal encrypted source-review disposition
until Profile/account deletion.

Applying a synchronized review decision also retires matching proposals already
saved or open for review on the observing device. Reconcile known decisions and
current source/target state before presentation, acceptance or result publication;
late work cannot restore the retired proposal. Delayed accepted-record delivery
does not authorize a duplicate or a link into another Profile. Apply the product
contract's reviewed-proposal scope without suppressing distinct obligations or
fresh reviewed updates. An offline device applies remote decisions when observed.

The 2026-10-14 decision panel chose deterministic convergence when offline
devices have already accepted the same matching creation proposal within one
Profile. Synchronization leaves one logical commitment, combines independent
authored edits and preserves competing values for the existing review. Preserve
current routing, reminder references and completion/deletion authority after
convergence. Distinct obligations, fresh updates and separately authored manual
records do not merge merely because they share correspondence. This selects no
identity, matching, storage or wire algorithm and adds no merge interaction.

Authored commitments survive source-message deletion and Mailbox Connection
removal. Retain reviewed title, state and dates with unavailable source links;
purge source content and connection-owned proposals. Profile/account deletion
removes commitments and review decisions. Connection moves preserve one owning
Profile and require review for mixed-source records, without cross-Profile source
access or silent copies. The existing lifecycle safety and authorization fences
remain in force.

Before connection removal is confirmed, disclose retained reviewed title, state,
dates and configured reminders in the app and Private Sync, purged source content and proposals, and
unavailable source links. Explain the existing Delete behavior for authored
content/reminders and its minimal retained decision, and the Profile/account
purge of records and decisions. The disclosure respects Profile Lock without
revealing protected content. This makes the retention trade-off visible at the
removal decision and adds no bulk-delete action.

Optional reminders reuse the Profile's notification owner and privacy controls.
An offline owner can show an alert made stale by an unsynchronized completion;
opening it cannot reopen the commitment. No scan, acceptance or reminder sends
mail or changes provider mail state. Full real native, model and Private Sync
qualification remains required across iPhone, iPad and Mac.

## Scope and supersession

For planned Mail Commitments only, this decision amends:

- [ADR 0052](0052-keep-mail-assistance-on-device-and-input-bound.md),
  [ADR 0053](0053-keep-mail-assistance-enablement-device-local.md) and
  [ADR 0059](0059-replace-the-client-for-a-shared-cross-platform-product.md):
  explicit-only invocation, ephemeral unaccepted previews, and destruction of
  every retained preview on Profile Lock. Their other privacy, availability and
  lifecycle restrictions remain.
- [ADR 0068](0068-allow-device-local-background-message-summaries.md): Catch Up
  summaries are no longer the sole automatic-assistance exception. Their
  body-cache budget, eviction and no-sync rules remain unchanged.
- The general mailbox-removal cleanup contract: the authored-record retention
  exception above does not retain source bodies, authorizations or generated
  proposals, and does not change Profile/account purge or provider mail.

The [power-user launch decision](0069-expand-the-apple-launch-to-power-user-mail.md)
and Product Sign-In scope remain unchanged. Compose, Response, Understanding and
Translation Assistance retain their existing input and acceptance contracts.
The canonical product note owns observable behavior and delivery order; technical
implementation choices not recorded here remain work for the future slices.

## Consequences

- The review queue can survive relaunch without becoming synchronized AI output.
- Reviewed obligation text may remain after mailbox removal, an explicit privacy
  trade-off that must be visible in removal behavior.
- Detection does not establish an obligation or prove fulfillment. Human review
  controls accepted state, dates and source relationships.
- Persistent decisions suppress repeated proposals without retaining deleted
  authored content or source-body copies.
