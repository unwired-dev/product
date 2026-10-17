# Outbox: architecture notes

Reviewer-only companion to [docs/outbox.md](../outbox.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).

## Delivery rules

- The Outbox lives in the account's encrypted
  [Draft document](../private-inbox-storage.md#draft-storage) on this device, the
  **Delivery Owner**. Admission removes the Draft and stores its exact content in
  the same write. The Outbox never synchronizes. Its files stay stored until the
  message is sent or returns to the Drafts.
- Before the provider sees the message, storage records it as handed over. A request
  whose answer may have been lost, an unreadable reply or an app stopped
  meanwhile reads as unknown, never as permission to send again.
- The Convex claim (`draftDelivery:claim`) names the Draft only by an opaque
  identifier that native code derives with the account's Private Sync keys,
  together with the claiming Trusted Device and the time. The first device to claim
  holds it for good. Asking again from that device, as after a lost reply, keeps the
  claim; other devices are refused. A claim whose reply is lost keeps the message
  waiting and is asked again. Claims are deleted with the Product Account.
- Native code reads each file's verified bytes from Draft storage and inserts
  them into the message, so they never cross the bridge. It sends through Gmail's
  multipart `messages.send` upload with the reply's thread. It accepts only ASCII
  message text from TypeScript and refuses a message over 35 MB.
- The message has HTML and plain-text alternatives built from the **Semantic Message
  Document**, followed by any quoted correspondence. Inline images are related
  parts referenced by Content-ID, and attachments carry RFC 2231 file names.
  Non-ASCII headers are RFC 2047 encoded and folded, with line breaks removed.
  Replies carry In-Reply-To and References, and join the Gmail thread only from the
  receiving mailbox (`threadOf`). Gmail removes Bcc from what others receive.
- Logs carry no message content, addresses or identifiers; claim and send failures
  log allow-listed codes only.

`createOutbox` in `@private-email/mail-core/outbox` runs delivery for both hosts.
`outgoingMessage` in `@private-email/mail-core/outgoing-message` builds the message.

## Durable state transitions

Admission also stores the rendered MIME segments, size and mailbox-scoped reply
thread. Native code inserts only verified asset bytes at handoff; retries never
rebuild the accepted message. Outbox transitions and Undo publish only after
their storage compare-and-set succeeds, rechecking the requested transition
against competing local progress after a conflict. A stale writer cannot roll
back a handoff or report a cancelled message while durable storage still queues it.

If storage refuses a known provider outcome, the running Outbox remembers it and
retries only recording that answer from `sending` or `unknown`, never provider
submission. Another store's conservative recovery to `unknown` cannot erase
the live handoff's known answer; only that handoff's Outbox holds the answer.
It forgets the answer when the entry advances or disappears and on disposal. A relaunch without
that saved answer still reads the durable handoff as unknown and checks Gmail's
Sent mailbox without resubmission.

## Unknown-outcome recovery (#616)

Reconciliation reads the newest 20 SENT messages and each one's Content-Type
metadata. Exactly one top-level MIME boundary matching the frozen outgoing message
confirms acceptance and records Gmail's message identifier through the existing
durable outcome path. Missing, conflicting or unavailable evidence retains unknown.
The lookup is bounded and never turns absence into permission to resend. Real
Gmail preservation of the boundary remains deferred release qualification.

The implementation decision panel chose the existing random MIME boundary over
adding a recipient-visible marker header, 3–0. It works with #615's persisted
messages without rebuilding their content. Both boundary parsers use positional
captures so host transforms that omit named capture groups do not break recovery.

Checks run when an entry first becomes unknown, on launch, activation and explicit
Check Again. Automatic checks wait for a ready mailbox with verified provider
access; the mailbox subscription retries a startup check after Draft storage opens
first. Disposal removes both Draft and mailbox subscriptions.

`findSent` returns no outcome when its open mailbox scope was unavailable or
invalidated, while an inconclusive Gmail lookup returns `unknown`. Reconciliation
restores automatic-check eligibility only for the former. Running lookups coalesce
explicit and automatic triggers; a ready publication observed during a lookup is
remembered and queues one fresh check if that lookup was interrupted. Readiness
arriving after interruption queues through the mailbox subscription. A completed
lookup consumes overlapping triggers without repeating provider reads.

The panel also chose Check Again plus warned Edit over Check Again plus Remove,
3–0. An unknown entry can return to Drafts only by the person's explicit choice
after the host warning; it retains its old claim and returns under a new identifier.
An in-flight `sending` entry remains ineligible for Edit.

## Retry scope for #615 and #616

The review decision panel selected the existing 30-second safe queued retry
policy over introducing durable attempt/age budgets in this slice, 3–0
(`claude-fable-5-1`, `gpt-6.1-sol`, `gpt-6-astra`, all high reasoning).
For #616, the implementation panel again chose the existing unlimited 30-second
and activation retries for definite queued non-delivery over durable attempt/age
budgets, 3–0, with the same models and reasoning settings. This supersedes the
#615 handoff assigning budgets to #616; the prototype's ADR 0016 budget remains
outside this replacement slice. Unknown outcomes remain excluded from automatic
resubmission under ADR 0062. These decisions do not qualify real Gmail, Convex or
native process-termination behavior.

## SMTP acceptance and filing (#631)

The same admission, originating-device ownership and frozen-message rules apply
to SMTP. A unique server-declared Sent folder is required before handoff. SMTP
messages add a Message-ID at admission. The shared Inbox leaves Bcc out of the
submitted segments. The native adapter inserts verified asset bytes and uses
To/Cc/Bcc as envelope recipients; the IMAP Sent copy retains the original segments
with Bcc.

A decoded SMTP acceptance is persisted as `filing`. Accepted messages cannot
return to Drafts; retries only file their Sent copy. An unreadable acceptance
reply remains unknown, and an unreadable filing reply keeps filing pending.
If the known acceptance cannot be saved, the existing live outcome retention
retries recording it without another submission. A relaunch without that answer
keeps the original durable handoff unknown.

Filing searches before APPEND using the frozen MIME boundary, so a lost reply or
relaunch finds an already-filed copy. Unknown reconciliation confirms exactly one
copy in the unique Sent folder; absence or ambiguity never authorizes resubmission.
Removing the connection settles an accepted entry without filing its remaining
copy. Shared controlled-provider tests and hosted iOS wire evidence are distinct;
real-provider and full native send journeys remain deferred release qualification.

## Microsoft acceptance and Sent Items (#636)

Microsoft uses the same immutable admission, assets, Undo Send, Convex claim and
originating-device ownership. Admission adds a Message-ID and enforces a
3,000,000-byte MIME limit. Native code inserts verified assets and submits the
base64 message through Graph's own-mailbox `sendMail` with a current device proof.
The [Microsoft companion](microsoft-mail.md#sending-and-uncertain-outcomes) records
the transport boundary and the panel-approved larger-message follow-up.

An empty 202 response records acceptance without waiting for Microsoft to file
Sent Items. Unknown outcomes instead search that folder by the frozen Message-ID;
only exactly one match from a complete result confirms acceptance. Missing,
ambiguous or unavailable evidence never permits resubmission. Definite refusals
retain the existing retry policy; refused consent requests Microsoft authorization
again without changing the selected connection or Delivery Owner. Controlled
provider and native-adapter checks remain distinct from live Graph and packaged
send-journey qualification.
