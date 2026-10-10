# Outbox: architecture notes

Reviewer-only companion to [docs/outbox.md](../outbox.md).
Read under the [implementation and review workflow](../agents/implementation-review.md).

## Delivery rules

- The Outbox lives in the account's encrypted
  [Draft document](../private-inbox-storage.md#draft-storage) on this device, the
  **Delivery Owner**. Admission removes the Draft and stores its exact content in
  the same write. The Outbox never synchronizes. Its files stay stored until the
  message is sent or returns to the Drafts.
- Before Gmail sees the message, storage records it as handed over. A request
  whose answer may have been lost, an unreadable reply or an app stopped
  meanwhile reads as unknown, never as permission to send again.
- The Convex claim (`draftDelivery:claim`) names the Draft only by an opaque
  identifier that native code derives with the account's Product Sync keys,
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

If storage refuses a known Gmail outcome, the running Outbox remembers it and
retries only recording that answer from `sending` or `unknown`, never Gmail
submission. Another store's conservative recovery to `unknown` cannot erase
the live handoff's known answer; only that handoff's Outbox holds the answer.
It forgets the answer when the entry advances or disappears and on disposal. A relaunch without
that saved answer still reads the durable handoff as unknown; #616 owns recovery.

## Retry scope for #615

The review decision panel selected the existing 30-second safe queued retry
policy over introducing durable attempt/age budgets in this slice, 3–0
(`claude-fable-5-1`, `gpt-6.1-sol`, `gpt-6-astra`, all high reasoning).
The prototype’s ADR 0016 retry budget is not imposed on #615. Recovery and retry
budgets belong with #616; unknown outcomes remain excluded from automatic
resubmission under ADR 0062.
