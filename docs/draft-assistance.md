# On-device Draft rewrites and reply suggestions

Setup, coding rules, validation and observable requirements remain in this file.

[#621](https://github.com/unwired-dev/product/issues/621) adds explicit
[Compose and Response Assistance](domain/assistance.md) to the composer on iPhone,
iPad and Mac: a meaning-preserving rewrite of authored Draft text, and one
suggested reply for a Reply or Reply All Draft. Both run on Apple's on-device
system language model. There is no cloud or product-backend model fallback.

## Behavior

- **Rewrite** sits in the formatting toolbar next to **Translate**. With text
  selected it rewrites the selection; with nothing selected it rewrites the whole
  authored body. It is disabled while that text is blank.
- **Suggest reply** appears only in a Reply or Reply All Draft that has its quoted
  message. It writes one complete reply that keeps the points already written.
- Choosing either action is the request: it captures the text and opens a review
  panel with progress and **Cancel**. Nothing runs before that.
- A rewrite reads only the captured authored text. A reply suggestion reads only
  the authored body, the display names of the To and Cc recipients and the Draft's
  already-local quoted message. It never reads recipient address fields, Bcc, the
  subject, attachments or Inline Images, and drops every word containing "@" from
  the names and quoted text. Any word cut at the input bound is dropped too,
  so no raw address or address fragment, such as the sender in the quoted
  attribution line, reaches the model. It never fetches mail, makes no Gmail
  request and never sends.
- Recipient context uses a 500-character name prefix, including separators.
  Names and quoted text are each bounded before addresses are removed; removing
  addresses does not extend either prefix.
- Captured authored text is never cut, because applying the result replaces all of
  it. Text whose encoded request exceeds 6,000 characters, or containing an Inline Image, is refused with
  guidance and the Draft is unchanged. The quoted message is cut so the whole reply
  input, including JSON framing and escaping, stays within 6,000 characters (never inside a surrogate pair), and a cut
  suggestion says so. If its only word exceeds the bound, no usable quoted text
  remains and the request is declined. Requests that leave no room for quoted text are declined
  before inference.
- The result is an ephemeral preview, marked as written on this device, possibly
  inaccurate and not saved. The Draft is unchanged until **Replace text** (rewrite)
  or **Use reply** (reply suggestion). That replaces exactly the captured text as
  one edit that one **Undo** reverts, keeping the capture's own leading and
  trailing whitespace. Line and list formatting is kept where the result keeps the
  line breaks; the inserted text takes the inline style (bold, italic and so on)
  of the text before it, as with Draft translation, because the model returns
  plain text. The preview says so. Recipients, the sender, the subject, quoted text,
  attachments, threading and delivery state are never changed. **Keep original**
  closes the panel.
- A result belongs to the text it was captured from. Any edit to the Draft body, or to the To/Cc recipients
  or quoted text used for a reply, cancels a pending request and closes its review, so a stale result is never
  offered or applied. Closing the Draft cancels the request. Controls rendered for
  an earlier state cannot affect a replaced or closed one.
- When the model cannot run, the Draft is unchanged and the panel says why, with
  the same reasons as [message summaries](message-summaries.md#behavior). A
  refusal, cancellation and other failures have their own messages. **Try again**
  is offered except on an ineligible device or after a refusal.

Not in this slice: the three concise reply directions and the question check that
[Response Assistance](domain/assistance.md) describes, subject suggestions,
drafting from scratch and proofreading. Mail Assistance Enablement, the per-Profile
opt-in, is [#788](https://github.com/unwired-dev/product/issues/788).

## Native binding

The methods are on the `UnwiredAssistance` module in
`native/private-inbox/bridge/UnwiredAssistance.swift`, which both hosts compile, so
no setup step is needed. Each checks availability like `summarize` and rejects with
the same codes.

| Method                         | Result                                                  |
| ------------------------------ | ------------------------------------------------------- |
| `rewrite(request, input)`      | The rewritten text                                      |
| `suggestReply(request, input)` | The reply body, without a subject, signature or quoting |
| `cancel(request)`              | Cancels that request's generation                       |

The shared core supplies `input` as a typed JSON request with an explicit
`operation`: `rewrite` carries `authoredText`; `reply` carries separate
`recipientNames`, `authoredText` and `quotedText` fields. Labels and field names
inside correspondence remain escaped content within their field. The 6,000-character
limit counts the complete encoded request. Authored text is preserved in full or
the request is refused; only quoted context can be shortened.

Each prompt treats its input as untrusted content, never as instructions, and forbids
inventing facts. Generation uses temperature 0 and at most 1,500 response tokens.
`@private-email/mail-core/assistance` decodes every result with Schema (up to
12,000 characters) and fails closed on anything else. Results containing image
placeholder characters are rejected, keeping the Draft unchanged rather than
applying text the editor would drop. Failure logs carry only the
allow-listed native code or decode path, never Draft or generated text.

## Deterministic evidence

- `packages/mail-core/test/assistance.test.ts` covers the admitted reply context
  (names and quoted text without addresses, the quoted message without images, the input bound and
  its disclosure, delimiter spoofing and JSON escaping), refused authored text, routing to `rewrite` or `suggestReply`,
  refusal, unavailability and failure without logging Draft text, retry rules, an
  oversized result, cancellation with a late result, and Mock Mail Session outcomes.
- The composer tests in `apps/mobile/test/composer.test.tsx` and
  `apps/macos/test/composer.test.tsx` rewrite the whole body and a selection,
  review and apply the whole-body result as one undoable edit without touching recipients, keep the
  original against a queued apply, show a refusal, cancel and retry, and drop a
  pending result when the body is edited or the Product Account changes. From the real reader with a synthetic
  Gmail mailbox, they request a reply suggestion for a Reply All Draft, check its
  admitted input and that no Gmail request is made, apply it to the authored body
  only, undo it, invalidate recipient edits even when Undo precedes a queued apply,
  and cancel a pending request on recipient changes or by closing the Draft.
- [Mock Mail Sessions](mock-mail-sessions.md#boundaries-and-scenarios) supply fixed
  rewrite and reply outcomes, and every selected native mock build answers with the
  same fixed synthetic text instead of running the model.

These are mocked journeys. They do not show that Apple's model runs or what it
writes.

## Deferred native checks

Running the binding on iOS, iPadOS and macOS 27 with Apple Intelligence enabled
on eligible hardware is deferred until that environment is available, together
with each unavailable reason and the context window on long input. It remains
required before release. Compilation of the bridge is not evidence of model
behavior.
