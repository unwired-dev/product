# On-device message summaries

Setup, coding rules, validation and observable requirements remain in this file.

[#620](https://github.com/unwired-dev/product/issues/620) adds the first
[Understanding Assistance](domain/assistance.md) action: an explicitly requested
summary of the opened message on iPhone, iPad and Mac, created by Apple's on-device
system language model. There is no cloud or product-backend model fallback.

## Behavior

- The reader shows **Summarize** once the message body is on this device. Nothing
  runs until the person chooses it, and opening a message never starts inference.
- The summary reads only the subject and the readable text already shown in the
  reader: the plain-text presentation of a Gmail body from the encrypted cache, or
  the preview fixture's body. It never fetches a missing body, more of a Thread,
  attachments, Inline Images or remote content, and it makes no Gmail request.
- Input is cut at 6,000 characters (never inside a surrogate pair). A cut summary
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

Mail Assistance Enablement, the per-Profile opt-in, is not part of this slice;
Mail Profiles do not exist yet.

## Native binding

Both hosts compile `native/private-inbox/bridge/UnwiredAssistance.swift` from the
shared bridge folder, so no setup step is needed. It uses `FoundationModels`
`SystemLanguageModel.default` and never `PrivateCloudComputeLanguageModel`. The
module offers:

| Method                      | Result                                                                                                                  |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `availability()`            | `available`, `device-ineligible`, `assistance-disabled`, `model-not-ready` or `unsupported-locale`                      |
| `summarize(request, input)` | The summary text, or a rejection coded `refused`, `cancelled`, `unsupported-locale`, `model-not-ready` or `unavailable` |
| `cancel(request)`           | Cancels that request's generation                                                                                       |

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

These are mocked journeys. They do not show that Apple's model runs or what it
writes.

## Deferred native checks

Running the binding on iOS, iPadOS and macOS 27 with Apple Intelligence enabled
on eligible hardware is deferred until that environment is available, together
with each unavailable reason on real devices. It remains required before release.
Compilation of the bridge in both host builds is not evidence of model behavior.
