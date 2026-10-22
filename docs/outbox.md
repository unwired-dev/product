# Sending Drafts through the Outbox

Setup, coding rules, validation and observable requirements remain in this file.

[#615](https://github.com/unwired-dev/product/issues/615) adds **Send** to the
composer on iPhone, iPad and Mac. A sent Draft leaves the Drafts list for the
**Outbox**, waits out the **Undo Send Window**, and is handed to Gmail from this
device. [#631](https://github.com/unwired-dev/product/issues/631) sends from IMAP
connections through their SMTP server with the same rules, then files a copy in their
Sent folder, as [IMAP sending](imap-mailboxes.md#sending) describes.
[#636](https://github.com/unwired-dev/product/issues/636) sends from Microsoft
connections through Graph with the same rules, as
[Microsoft sending](microsoft-mail.md#sending) describes. The rules below name Gmail
where IMAP and Microsoft wording differs only by provider. A handoff whose outcome is uncertain is never resubmitted; only a definite
refusal, such as a rate limit, is tried again.
[#616](https://github.com/unwired-dev/product/issues/616) recovers interrupted sends
after a relaunch and reconciles uncertain ones with Gmail's Sent mailbox. Sending
with Mac windows closed and pausing within mobile execution limits is
[#618](https://github.com/unwired-dev/product/issues/618).

## Application execution

The application owns Outbox processing independently of any Inbox screen or Mac
window. On Mac, closing the last window leaves queued work running. Explicit
Quit stops execution with the process; reopening recovers this device's durable
Outbox, including its original Undo Send deadlines and confirmed claims.

On iPhone and iPad, new delivery starts only while the application is active.
Leaving the foreground pauses timers and fences work awaiting a claim, a storage
write or refreshed native credentials. Returning retries due work; it does not
restart an Undo Send Window. Background Inbox refreshes and push wakes do not
grant permission to send. Delivery does not promise mobile background execution.

[Mock Mail Session](mock-mail-sessions.md) builds use the same lifecycle and Undo
Send Window with their synthetic providers.

A provider request already started settles through the existing outcome rules.
Suspension, termination, sign-out, connection removal or device revocation cannot
turn an uncertain handoff into permission to submit again. Native submission
revalidates account, connection and current device trust before renewing Gmail or
Graph credentials and again before handoff, then checks execution permission.
Removal hides or purges private local data under the account and connection
policies; the backend retains only the content-free
delivery claim needed to refuse takeover, until Product Account deletion removes
it.

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
  - is over its provider's message limit: 35 MB for Gmail, 3 MB for Microsoft;
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
  Gmail had it. The message is never sent again automatically.
  A connection that never reached Gmail (no network, no host, or a secure
  connection that was never established) is not unknown: the message waits to send.
- The app looks for an unknown message in Gmail's Sent mailbox when its outcome
  becomes unknown, when the app starts or becomes active, and when **Check Again** is
  pressed, waiting for its mailbox to open at launch. It checks a limited set of
  recent Sent messages; an older message can remain unknown. Unambiguous confirmation
  records the message as sent and removes it from the Outbox. No confirmation,
  conflicting evidence, or Gmail being unreachable keeps it
  unknown; after **Check Again**, the row says Gmail did not confirm it. Every Mac
  window showing the message shows the same check in progress and the same answer,
  and pressing **Check Again** again while it runs starts no second lookup.
  If the check finds locked storage, the Inbox hides its mail; device removal
  closes it, and refused Gmail access asks for authorization again, including
  after an offline retry. The delivery outcome remains unknown.
- A message whose mailbox is no longer connected, as after its removal, names no
  provider: it asks to check the Sent folder of the mailbox it was sent from.
- **Edit** on an unknown message first warns that Gmail may already have sent it,
  and asks to check Sent in Gmail, only in the window where it was pressed.
  **Edit Anyway** returns it to the Drafts; sending it again is the person's
  deliberate choice.
- **Edit** returns the message to the Drafts and opens it. A message whose claim
  was requested returns under a new identifier, because its old one stays claimed.
- After a relaunch, only this device continues its Outbox. A message within the
  Undo Send Window keeps its deadline and Undo. A queued message resumes its claim
  or handoff from the stored state, and a claim is never assumed: one whose reply
  never arrived is asked for again, and Convex keeps it for this device. A message
  stored as handed to Gmail is unknown and is only reconciled, never resubmitted.
  A Sign in with Apple device sends after a relaunch without signing in again,
  although its Drafts wait for the next interactive sign-in to synchronize.

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
- A claim is proven by this Trusted Device's own credential, without a Product
  Sign-In, which Sign in with Apple cannot renew after a relaunch. Convex refuses
  a missing or wrong credential, a device that predates device credentials, a
  device of another account, a removed device and a Product Account being deleted.
- When storage refuses to record Gmail's answer, the app saves it again with the
  next retry while it keeps running, so a message Gmail never received stays
  retryable rather than reading as unknown.
- Native code owns encrypted file access and Gmail and SMTP credentials. Keys, credentials
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
- the app stopping before Convex receives the claim, after Convex takes it but before
  its reply, after the claim is held, after the handoff is recorded but before Gmail
  receives the message, and after Gmail accepts it but before its answer is recorded,
  each followed by two relaunches without a second Gmail copy;
- an accepted message whose answer was lost, confirmed from Gmail's Sent mailbox;
- mailbox loading after reopened Draft storage, boundary parsing without named
  capture groups in the host runtime, and conflicting or unavailable Sent evidence;
- mailbox refresh interrupting a Sent check, with readiness returning before or
  after the interrupted check answers, and overlapping Check Again requests sharing
  one provider lookup;
- an unknown message that Gmail never kept, which stays unknown through
  **Check Again** and returns to the Drafts under a new identifier;
- a renamed sender while queued, during a claim, or while handoff is being saved,
  without submitting the frozen message;
- a mailbox refresh refusing handoff before submission, retaining the claim and
  sending on the next pass;
- each refusal at Send.

`outbox-lifecycle.test.ts` exercises pause/resume across Undo Send, claims,
durable handoff writes, disposal and in-flight outcomes, and authority loss from
sign-out, connection removal and device revocation before and after submission.
The host `delivery.test.tsx` journeys run application entry wiring with real shared
stores and synthetic native storage, Gmail and claims, without mounting an Inbox.
They prove mobile foreground gating and Mac processing with no mounted windows.
Cold shared-store journeys reopen Draft storage with fresh, unloaded mailbox
stores and recover queued handoffs, unknown outcomes and accepted SMTP Sent
copies without another submission.
These are deterministic integration checks, separate from native lifecycle and
real-provider qualification.

`imap-send.test.ts` runs the same Outbox through SMTP and Sent filing, as
[IMAP mailboxes](imap-mailboxes.md#validate) lists.
`microsoft-send.test.ts` runs it through Graph and Sent Items, as
[Microsoft mail](microsoft-mail.md#deterministic-evidence) lists.

`outgoing-message.test.ts` checks header folding, encoding and injection, the
exact message size, and the HTML and plain-text block structure.

`packages/convex/test/draftDelivery.test.ts` covers concurrent claims proven by
the device credential alone, repeating a held claim, other accounts, malformed
identifiers, another device's credential, devices without credentials, account
deletion and revoked devices, including sign-out retaining a content-free claim
that prevents another device taking over. The account
deletion test removes claims.

The host journeys in `apps/*/test/send.test.tsx` send from the composer, use
**Undo** and send again. They also show a refused Send, a Gmail refusal with
**Edit**, a lost answer confirmed from Gmail's Sent mailbox, and an unknown outcome
with **Check Again** and the warning before **Edit Anyway**, and an unknown message whose
mailbox is no longer listed in provider-neutral words. These are rendered component tests.
The composer journeys also retain the original sender after a mailbox rename and
choose its current address explicitly before reopening the Draft.

The hosted iOS 27 suite adds `OutboxTests`:

- the multipart upload with the file's verified bytes as base64 lines and the reply
  thread;
- refusal of non-ASCII text, malformed segments, moved or damaged bytes, and a
  stale mailbox generation before any request;
- a returned Gmail refusal, and an unknown outcome once a request started;
- losing native execution permission or device trust during credential refresh,
  before any handoff;
- already-revoked Gmail and Graph sends purging local registration without
  refreshing credentials;
- opaque claim identifiers held by one device, also claimed without a Product
  Sign-In session, as after a Sign in with Apple relaunch.

The `registration-apple` [Mock Mail Session](mock-mail-sessions.md) native journey
ends by sending a new message after a relaunch: the row says **Sending soon**, and
the synthetic provider's acceptance removes it from the Outbox, on iPhone and
iPad. CI does not run
this scenario; it is local native evidence.

Deferred before release:

- native Mac send journeys;
- real Gmail delivery qualification against Apple Mail, Gmail and Outlook,
  including threading, inline images and large attachments;
- confirming against real Gmail that a Sent copy keeps the message's MIME boundary,
  so an unknown outcome can be reconciled (otherwise it safely stays unknown);
- native process termination at each delivery step on iPhone, iPad and Mac;
- real Convex claims between two signed Trusted Devices;
- VoiceOver qualification of Send, the Outbox rows, their live status and the
  unknown-outcome recovery actions.
