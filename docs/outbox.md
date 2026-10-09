# Sending Drafts through the Outbox

Setup, coding rules, validation and observable requirements remain in this file.

[#615](https://github.com/unwired-dev/product/issues/615) adds **Send** to the
composer on iPhone, iPad and Mac. A sent Draft leaves the Drafts list for the
**Outbox**, waits out the **Undo Send Window**, and is handed to Gmail once, from
this device. Recovery after an interrupted send is
[#616](https://github.com/unwired-dev/product/issues/616), and sending with the app
in the background or with Mac windows closed is
[#618](https://github.com/unwired-dev/product/issues/618).

## Sending

- **Send** first turns any address still being typed into a recipient. It sends
  the Draft exactly as the composer shows it when pressed and then closes the
  composer. It refuses, and keeps the Draft open with the reason, when the Draft:
  - has no recipient;
  - has text that is not a valid address;
  - sends from a mailbox that cannot send;
  - has a file that is still importing, failed, or does not verify on this device;
  - is over Gmail's 35 MB message limit;
  - was changed in another window meanwhile;
  - cannot be saved.
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
- **Not sent** explains a definite refusal and offers **Edit**:
  - another of the account's devices claimed the Draft first;
  - the mailbox needs Gmail access again or is no longer connected;
  - its files are no longer on this device;
  - it is too large;
  - Gmail refused it.
- **Delivery unknown** means Gmail may have the message: the request started but
  no answer arrived, Gmail answered with a server error, or the app stopped while
  Gmail had it. The message is never sent again automatically and offers no Edit;
  check Gmail's Sent mailbox. Explaining and reconciling it is #616.
- **Edit** returns the message to the Drafts and opens it. A message whose claim
  was requested returns under a new identifier, because its old one stays claimed.

## Delivery rules

- The Outbox lives in the account's encrypted
  [Draft document](private-inbox-storage.md#draft-storage) on this device, the
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

## Verification

```sh
mise exec -- pnpm --filter @private-email/mail-core test
mise exec -- pnpm --filter @private-email/convex test
mise exec -- pnpm --filter @private-email/mobile test
mise exec -- pnpm --filter @private-email/macos test
mise exec -- zsh native/private-inbox/integration/test.zsh ios
```

Shared journeys in `packages/mail-core/test/outbox.test.ts` use the real Draft
store, Gmail Inbox and Outbox with synthetic Draft storage, Gmail and Convex
claims. They send a formatted reply with an inline image and an attachment once
after the Undo Send Window, and parse it with an independent MIME parser. They also
cover:

- Undo before anything is claimed or sent, with the Draft continuing on another
  device;
- two devices sending the same Draft, of which one submits;
- an unreachable claim and a claim whose reply is lost;
- a Gmail refusal and an accepted message whose reply is lost, kept apart and
  never sent again through relaunch;
- the app stopping while Gmail has the message;
- each refusal at Send.

`outgoing-message.test.ts` checks header folding, encoding and injection, the
exact message size, and the HTML and plain-text block structure.

`packages/convex/test/draftDelivery.test.ts` covers concurrent claims, repeating
a held claim, other accounts, malformed identifiers and revoked devices. The account
deletion test removes claims.

The host journeys in `apps/*/test/send.test.tsx` send from the composer, use
**Undo** and send again. They also show a refused Send, a Gmail refusal with
**Edit**, and an unknown outcome without it. These are rendered component tests.

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
