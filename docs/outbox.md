# Sending Drafts through the Outbox

Setup, coding rules, validation and observable requirements remain in this file.

[#615](https://github.com/unwired-dev/product/issues/615) adds **Send** to the
composer on iPhone, iPad and Mac. A sent Draft leaves the Drafts list for the
**Outbox**, waits out the **Undo Send Window**, and is handed to Gmail from this
device. A handoff whose outcome is uncertain is never resubmitted; only a definite
refusal, such as a rate limit, is tried again. Recovery after an interrupted send is
[#616](https://github.com/unwired-dev/product/issues/616), and sending with the app
in the background or with Mac windows closed is
[#618](https://github.com/unwired-dev/product/issues/618).

## Sending

- **Send** first turns any address still being typed into a recipient. It sends
  the Draft exactly as the composer shows it when pressed and then closes the
  composer. It refuses, and keeps the Draft open with the reason, when the Draft:
  - has no recipient;
  - has text that is not a valid address;
  - has a sender or recipient address that is not plain ASCII, which native code
    cannot send;
  - sends from a mailbox that cannot send, or whose address changed since the Draft
    chose it;
  - has a file that is still importing, failed, or does not verify on this device;
  - is over Gmail's 35 MB message limit;
  - was changed in another window meanwhile;
  - cannot be saved.
- While Send is pending, the composer accepts no edits: its fields, Undo, Redo,
  formatting and Discard wait until the message is admitted or Send is refused.
  Send dismisses any translation or writing-help preview and prevents new requests;
  a refused Send restores editing and assistance actions.
- If a mailbox changes its address, **From** keeps the Draft's original address
  visible with an explanation. Choose that mailbox again to use its current
  address, or choose another mailbox.
- The **Outbox** appears in the Inbox column above the Drafts only while it holds
  a message. Each row names its subject and recipients and says where the message
  stands, and is hidden during search with the Drafts.
- For 10 seconds a row says **Sending soon** and offers **Undo**. Undo returns the
  same Draft, with its identifier, files and reply details, and opens it in the
  composer. Nothing reaches Convex or Gmail before the window ends. Choosing
  another window length is a later slice.
- After the window this device claims the Draft through Convex and only then
  hands it to Gmail. A message Gmail accepts leaves the Outbox. Once this device
  synchronizes, the Draft is gone from the account's other Trusted Devices.
- A message that could not reach Convex or Gmail, or found storage locked or Gmail
  rate limited, says it is **Waiting to send** and why. It tries again after 30
  seconds and whenever the app becomes active, and offers **Edit**.
  If storage is locked when the Undo Send Window ends, the message remains
  cancellable and retries after the same delay.
  A mailbox refresh that prevents handoff also keeps the message waiting;
  returning to the app does not turn an ordinary refresh into **Not sent**.
- **Not sent** explains a definite refusal and offers **Edit**:
  - another of the account's devices claimed the Draft first;
  - the mailbox needs Gmail access again, is no longer connected, or changed its
    address;
  - its files are no longer on this device;
  - it is too large;
  - Gmail refused it.
- **Delivery unknown** means Gmail may have the message: the request started but
  no answer arrived, Gmail answered with a server error, or the app stopped while
  Gmail had it. The message is never sent again automatically and offers no Edit;
  check Gmail's Sent mailbox. Explaining and reconciling it is #616.
  A connection that never reached Gmail (no network, no host, or a secure
  connection that was never established) is not unknown: the message waits to send.
- **Edit** returns the message to the Drafts and opens it. A message whose claim
  was requested returns under a new identifier, because its old one stays claimed.

## Delivery rules

- This device is the **Delivery Owner**. Admission removes the Draft and stores
  the exact rendered message and verified asset references in one encrypted write.
  The Outbox remains local; its files remain available through Undo and delivery.
- Undo succeeds only after cancellation is saved. If storage refuses it, the
  Outbox row remains available to try again.
- Before provider submission, the device must durably record both a confirmed
  Convex claim and the handoff state. A failed, interrupted or unreadable claim
  response never grants permission to submit.
- Claims contain no message content. Another device cannot take over delivery;
  an uncertain provider outcome never causes automatic resubmission.
- When storage refuses to record Gmail's answer, the app saves it again with the
  next retry while it keeps running, so a message Gmail never received stays
  retryable rather than reading as unknown.
- Native code owns encrypted file access and Gmail credentials. Keys, credentials
  and asset bytes never cross the JavaScript bridge; logs contain no mail content,
  addresses or identifiers.
- Sent messages preserve the formatted body, plain-text alternative, quoted
  correspondence, attachments, inline images and eligible reply threading.

The reviewer-only [Outbox companion](architecture/outbox.md) records internal
mechanisms and the scope of the retry policy.

## Verification

```sh
mise exec -- pnpm --filter @private-email/mail-core test
mise exec -- pnpm --filter @private-email/convex test
mise exec -- pnpm --filter @private-email/mobile test
mise exec -- pnpm --filter @private-email/macos test
mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

Shared journeys in `packages/mail-core/test/outbox.test.ts` and
`outbox-recovery.test.ts` use the real Draft
store, Gmail Inbox and Outbox with synthetic Draft storage, Gmail and Convex
claims. They send a formatted reply with an inline image and an attachment once
after the Undo Send Window, and parse it with an independent MIME parser. They also
cover:

- Undo before anything is claimed or sent, with the Draft continuing on another
  device, and refusal when cancellation cannot be saved;
- two devices, or two local storage writers, sending the same Draft, of which
  one submits;
- preserving a confirmed send when a stale storage writer saves;
- automatic delivery after the Undo Send deadline and cancellation of scheduled
  work when the Outbox is disposed, with delayed retries when storage is locked;
- reclaiming sent files without another Draft edit or app relaunch;
- immutable message segments through retries and folded long headers and file
  names that round-trip through an independent MIME parser;
- an unreachable claim and a claim whose reply is lost;
- a Gmail refusal and an accepted message whose reply is lost, kept apart and
  never sent again through relaunch;
- the app stopping while Gmail has the message;
- a renamed sender while queued, during a claim, or while handoff is being saved,
  without submitting the frozen message;
- a mailbox refresh refusing handoff before submission, retaining the claim and
  sending on the next pass;
- each refusal at Send.

`outgoing-message.test.ts` checks header folding, encoding and injection, the
exact message size, and the HTML and plain-text block structure.

`packages/convex/test/draftDelivery.test.ts` covers concurrent claims, repeating
a held claim, other accounts, malformed identifiers and revoked devices. The account
deletion test removes claims.

The host journeys in `apps/*/test/send.test.tsx` send from the composer, use
**Undo** and send again. They also show a refused Send, a Gmail refusal with
**Edit**, and an unknown outcome without it. These are rendered component tests.
The composer journeys also retain the original sender after a mailbox rename and
choose its current address explicitly before reopening the Draft.

The hosted iOS 27 suite adds `OutboxTests`:

- the multipart upload with the file's verified bytes as base64 lines and the reply
  thread;
- refusal of non-ASCII text, malformed segments, moved or damaged bytes, and a
  stale mailbox generation before any request;
- a returned Gmail refusal, and an unknown outcome once a request started;
- opaque claim identifiers held by one device.

Deferred before release:

- native iPhone, iPad and Mac send journeys;
- real Gmail delivery qualification against Apple Mail, Gmail and Outlook,
  including threading, inline images and large attachments;
- real Convex claims between two signed Trusted Devices;
- VoiceOver qualification of Send, the Outbox rows and their live status.

The packaged Mock Mail Session accepts sends in synthetic Gmail, but no native
journey drives them yet.
