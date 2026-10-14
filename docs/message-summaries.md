# On-device message summaries

Setup, coding rules, validation and observable requirements remain in this file.

[#620](https://github.com/unwired-dev/product/issues/620) adds the first
[Understanding Assistance](domain/assistance.md) action: an explicitly requested
summary of the opened message on iPhone, iPad and Mac, created by Apple's on-device
system language model. There is no cloud or product-backend model fallback.

## Behavior

- The reader shows **Summarize** once the message body is on this device and
  [Mail Assistance Enablement](#mail-assistance-enablement) is on. Nothing
  runs until the person chooses it, and opening a message never starts inference.
- The summary reads only the subject and the readable text already shown in the
  reader: the plain-text presentation of a Gmail or Microsoft body from the encrypted cache, or
  the preview fixture's body. It never fetches a missing body, more of a Thread,
  attachments, Inline Images or remote content, and it makes no provider request.
- Subject and body text are shortened so the complete JSON request, including framing and escaping, fits within 6,000 characters (never cutting a surrogate pair). A cut summary
  says that only the beginning of the long message was summarized.
- While the model works, the reader shows progress and **Cancel**. Cancelling
  stops the native request; a result that still arrives is dropped. Cancelling
  during the availability check prevents generation from starting afterward.
- A summary is an ephemeral preview beside the unchanged message, marked as created
  on this device, possibly inaccurate and not saved. **Dismiss** forgets it. It is
  never stored, synchronized or written into mail or Drafts.
- A result belongs to the message, mailbox store and input text it was requested
  for. Opening another message, switching mailbox or account, or a changed body
  cancels the request and forgets the preview before the next render shows it.
- When the model cannot run, the message stays fully readable and the reader says
  why: the device does not support Apple Intelligence, Apple Intelligence is turned
  off, the model is still getting ready, or the device language is not supported.
  A refusal and other failures have their own messages. **Try again** is offered
  except on an ineligible device or after a refusal.

## Mail Assistance Enablement

[#788](https://github.com/unwired-dev/product/issues/788) puts every explicit
On-Device Mail Assistance action, **Summarize**, Draft
[**Rewrite** and **Suggest reply**](draft-assistance.md) and
[**Translate**](message-translation.md), behind
[Mail Assistance Enablement](domain/assistance.md):

- It is off by default on every device. While it is off, none of those actions
  appears and nothing reaches Apple's model or Translation.
- **On-device assistance** on the account page turns it on or off for the
  signed-in Product Account's Mail Profile on this device. Only the
  [Default Profile](private-inbox-storage.md#mail-profiles) exists, so there is one
  choice. Readers use their window’s Profile consent, while Account settings and
  Drafts retain the Default consent path until Profile lifecycle arrives. Turning
  it on starts none of these explicit actions; each still requires a request.
  Separately confirmed post-launch [Mail Commitments](product/mail-commitments.md#automatic-scanning)
  explain automatic scanning in their enablement consent and require renewed
  device/Profile confirmation when earlier consent did not cover that scope.
- While assistance is on, **Check Apple Intelligence availability** explicitly
  checks whether the system model can run, without generating text or prewarming
  it. The account page reports eligibility, Apple Intelligence configuration,
  model readiness or language support. Availability for Translation remains
  separate. Opening the page or changing enablement never runs this check.
- A device choice that is still saving or could not be saved is shown as such,
  with an explicit retry for the failed save. Turning assistance off still closes
  its actions immediately, even when saving fails.
- Turning it off, in any window, cancels that Profile’s in-flight assistance and
  forgets its shown previews, including its account-page availability status. A captured Draft
  request is retired, so turning it on again does not restart it.
- It is stored only in this device's Keychain, never synchronized or restored to another device.
  A Pending Device, or an account whose sign-out or deletion is under way, has
  none. Sign-out, Product Account deletion and removal of this device by another
  Trusted Device purge it, so signing in again starts with it off.
- Until the device's choice is read, after every account change, assistance stays
  off. A failed read leaves it off.
- Turning it off takes effect before saving finishes, including when an earlier
  save is still pending. Queued actions and replies from an earlier account
  cannot enable a replacement account or restore a discarded preview. Turning it
  off also prevents pending language lookups from reaching Apple Translation.

Planned [Catch Up](catch-up.md#summaries) background summaries reuse this binding
but run without a per-message request; they are not part of this slice.

## Native binding

Both hosts compile `native/private-inbox/bridge/UnwiredAssistance.swift` from the
shared bridge folder, so no setup step is needed. It uses `FoundationModels`
`SystemLanguageModel.default` and never `PrivateCloudComputeLanguageModel`. The
module offers:

| Method                      | Result                                                                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `availability()`            | `available`, `device-ineligible`, `assistance-disabled`, `model-not-ready` or `unsupported-locale`                                     |
| `summarize(request, input)` | The summary text, or a rejection coded `refused`, `cancelled`, `unsupported-locale`, `model-not-ready` or `unavailable`                |
| `cancel(request)`           | Cancels that request's generation, including a [Draft rewrite or reply](draft-assistance.md), or [translation](message-translation.md) |

The shared core supplies `input` as a typed JSON request with `operation: summary`
and separate `subject` and `body` fields. Text that looks like a label or JSON field
remains escaped content inside its source field.

The prompt treats the email as untrusted content to describe, never as
instructions, and asks for at most four sentences covering the topic, requests,
questions and stated dates or deadlines. Generation uses temperature 0 and at most
300 response tokens. `@private-email/mail-core/assistance` checks availability
before each request, decodes every native result with Schema (summaries up to
4,000 characters) and fails closed on anything else. Failure logs carry only the
allow-listed native code or decode path, never mail or summary text.

## Deterministic evidence

- `packages/mail-core/test/assistance.test.ts` covers the input bound and
  disclosure, every availability and rejection outcome, malformed, oversized and
  empty results, log privacy, cancellation with a late result or a pending
  availability check, and results kept only for their own input.
- `apps/mobile/test/summary.test.tsx` and `apps/macos/test/summary.test.tsx` drive
  the real reader with the real Gmail store and a synthetic Gmail mailbox. They
  verify that summarizing reads only the local text and makes no Gmail request,
  that unavailable assistance leaves the message readable, cancellation, and
  that switching messages cancels the request and drops its late result, through
  both the Gmail reader and the preview fixture. Changed captured input discards
  both completed previews and pending work, even if the input later changes back.
  A layout-phase observer also verifies that pending availability requests are
  cancelled during reader replacement and unmount, before passive cleanup, and
  that the store remains usable after StrictMode replay.
- [Mock Mail Sessions](mock-mail-sessions.md#boundaries-and-scenarios) supply fixed
  assistance outcomes, and every selected native mock build answers with the
  same fixed synthetic summary instead of running the model.

- `packages/mail-core/test/assistance-enablement.test.ts` covers the default, the
  Product Account and Profile scope, persistence, immediate turn-off, removal by
  sign-out and deletion, stale and malformed reads, and the Mock Mail Session
  outcomes, including same-account re-entry and queued-save races.
  `apps/mobile/test/mail-assistance.test.tsx` and
  `apps/macos/test/mail-assistance.test.tsx` drive the real registration gate and
  reader over the synthetic registration session: actions stay hidden and nothing
  reaches either framework until the account page turns assistance on, turning it
  off cancels an in-flight summary and drops its late result. Explicit account-page
  availability checks report every model outcome without generation, fail closed
  on malformed or rejected replies, and forget late results after Off, account
  replacement or unmount. Failed preference saves keep assistance off and offer
  an explicit retry. Signing out and in again leaves it off. Both composer suites check that Draft assistance and
  translation appear only while enabled and that turning it off retires a pending
  request before React commits, refusing queued controls. The hosted native storage suite checks that the Keychain item belongs to
  its account and that every purge removes it.

These are mocked journeys. They do not show that Apple's model runs or what it
writes.

## Deferred native checks

Running the binding on iOS, iPadOS and macOS 27 with Apple Intelligence enabled
on eligible hardware is deferred until that environment is available, together
with each unavailable reason on real devices. It remains required before release.
Compilation of the bridge in both host builds is not evidence of model behavior.
Turning Mail Assistance Enablement on and off, and its removal by sign-out, on
signed iOS, iPadOS and Mac builds with a real Product Account is deferred with them.
