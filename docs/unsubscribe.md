# Unsubscribe

[#2060](https://github.com/unwired-dev/product/issues/2060), the first slice of
[#654](https://github.com/unwired-dev/product/issues/654), finds the
[Unsubscribe Suggestion](domain/organization.md) an opened message offers, and
[#2077](https://github.com/unwired-dev/product/issues/2077) sends its one-click
request, [#2823](https://github.com/unwired-dev/product/issues/2823) remembers each
request that was sent, and [#2824](https://github.com/unwired-dev/product/issues/2824)
sends a `mailto:` request through the Outbox.
[#2967](https://github.com/unwired-dev/product/issues/2967) adds the Mac reader's
banner, confirmation and outcomes for one-click offers and
[#2968](https://github.com/unwired-dev/product/issues/2968) its `mailto:` states,
under [ADR 0044](adr/0044-isolate-standards-based-unsubscribe-actions.md).

## Finding the offer

When a Gmail, Microsoft Graph or IMAP message opens, its body document keeps
`List-Id`, `List-Unsubscribe` and `List-Unsubscribe-Post` beside the headers
Reply reads, each up to 64 KiB. Graph passes them through from
`internetMessageHeaders`. A body cached before these headers were kept shows no
offer until it is read again.

`unsubscribeOf` (`@private-email/mail-core/unsubscribe`) reads only those
headers, never body prose:

- **One-click** ([RFC 8058](https://www.rfc-editor.org/rfc/rfc8058)): the first
  `https:` URI in `List-Unsubscribe` when `List-Unsubscribe-Post` is exactly
  `List-Unsubscribe=One-Click`.
- Otherwise **mailto** ([RFC 2369](https://www.rfc-editor.org/rfc/rfc2369)): the
  first `mailto:` URI naming exactly one valid address. Only its `subject` and
  `body` fields are kept, so fields such as `cc` never add recipients.
- Otherwise nothing: an `https:` link without the one-click header (an
  unsubscribe page: the approved frames show no Open Unsubscribe Page action, so
  ADR 0044's page action waits for a later slice), `http:` and other schemes, an
  HTTPS address with user information, a bracketed IP address or a port outside
  1–65535, unbracketed URIs, several `mailto:` addresses and undecodable escapes.

URIs must be in angle brackets; whitespace inside the brackets is ignored, as
RFC 2369 asks, and a bracketed URI inside a comment is not one, even when it holds
parentheses. Field names and
values are percent-decoded. The offer names the list by the `List-Id` phrase,
such as `Alza.cz newsletter` in `Alza.cz newsletter <newsletter.alza.example>`,
else by the sender's display name or address. With no name there is no offer.
Its **Mailing List Identity**, which scopes the request's record, is the
`List-Id` identifier in angle brackets, such as `newsletter.alza.example`, in
lower case. Only an [RFC 2919](https://www.rfc-editor.org/rfc/rfc2919) identifier
counts: dot-separated atoms, which no URI with a scheme matches. Whitespace around
its dots is ignored. A sender's address is not an identity, since several lists can share
it, so an offer without a valid `List-Id` has none.

The check is syntactic. It does not verify that a DKIM signature covers the
list headers, so the confirmation names the list and the receiving address, and
the later request boundary will reject non-public destinations
([ADR 0044](adr/0044-isolate-standards-based-unsubscribe-actions.md)). Header
values stay on the device: they are never logged, sent to Convex or included in
Product Sync.

## Sending the one-click request

`requestUnsubscribe(native, offer)` sends a one-click offer's request once,
after the person confirms it. The native module (`OneClickUnsubscribe`) posts
only the RFC 8058 body `List-Unsubscribe=One-Click` as
`application/x-www-form-urlencoded`, over the transport remote images use
(`RemoteContent.swift`): HTTPS only, no cookie, credential, referrer or shared
session, one validated public address pinned while TLS authenticates the
original host name, and a 30-second deadline for the whole request. A 307 or
308 redirect repeats the POST at the new location after the same checks, at
most three times. No mailbox credential takes part, and mock builds never reach
a server.

The request ends in one of three outcomes:

| Outcome     | When                                                                                                                                                                                |
| ----------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `sent`      | The server answered 2xx, after any interim 1xx answers. Copy says only that the request was sent, never that mail stops.                                                            |
| `failed`    | Nothing was sent (the destination was refused, unresolvable or unreachable, or the deadline passed first), or the server answered with another status.                              |
| `uncertain` | The request may have arrived without a usable answer: the answer was lost, cut off or unreadable, the deadline passed after sending, or the server redirected with 301, 302 or 303. |

Nothing retries after a request was sent: a lost answer does not prove the
request failed, so only the person can send it again. A rejected or malformed
native answer is `uncertain` for the same reason.

## Sending a mailto request

`outbox.unsubscribe(connection, offer, source)` admits a `mailto:` offer's
request once, after the person confirms it. `connection` is the Mailbox
Connection that received `source`, the message that offered it. The request is an ordinary message from that connection's
address to the offer's one address, with only the offer's `subject` and `body`:
no Cc, Bcc, reply headers or other `mailto:` fields. Each line of the body is a
paragraph. It is never a Draft, so it never syncs. Admissions run one at a
time: while the Outbox holds a request for the same connection and list, a
second confirmation, as from another window, answers with that request, and
only a refused or unknown one is tried again. Trying one again sends the same
recipient, subject and body, never another message's offer for the list, and a
refused one leaves the Outbox once its retry is admitted, or, while storage
keeps it, once the retry is confirmed. A retry keeps the identifiers of the
requests it tries again, also through a refused retry: once one of them is confirmed, a further confirmation answers with that
one, and a retry not yet handed off leaves the Outbox unsent, answering as that
one did; the handoff checks again as it marks the retry sending and just before
the provider sees it. The reader passes the requests it showed for the message
(`outbox.unsubscribe(connection, offer, { message, retrying })`), and one of
them confirmed meanwhile also answers in place of another. Once a retry is
confirmed, the unknown requests it tried again are marked answered: they stay
in the Outbox for Check Again but no longer stand for the list, so a message the
list sends after the 14 days offers a fresh request with its own recipient. The
retry stays in the Outbox until each mark holds in storage, and Check Again
finding an answered request in Sent, or one a confirmed retry still in the
Outbox tried again, retires it without recording it again, so the list's 14
days still run from the retry. The reader keeps showing the retry's receipt,
with its recipient, rather than the answered request's date.

It waits in the Outbox under the Undo Send Window and is then claimed and sent
like any message, so it appears in the connection's Sent mailbox and an
uncertain handoff is never sent again automatically. Undo only takes it out of
the Outbox; its Outbox row, like an Invitation Response's, has no Edit, since it
was never a Draft. Nothing logs the address, subject or body, and Convex hears
only the claim's opaque identifier.

The Outbox entry keeps the Product Account that admitted it, the Mail Profile
that owns the connection, the list's name, its Mailing List Identity and the
source message. Once the provider confirms the send, or
Check Again finds it in Sent, the Outbox records the request through the
`requests` it was created with (the host's `unsubscribe.record`) before the
entry leaves, so a relaunch in between loses neither the request nor its
record. While storage refuses the record, the entry stays in the Outbox with the
time the provider confirmed it, saved again later and after a relaunch with that
same time, and is never sent again; the reader shows it sent at once. An IMAP
request keeps that time as soon as its Sent copy is filed and never files it
again, even after a refused step or a relaunch, so a copy the person moved or
deleted meanwhile stays that way. A record
older than the one storage holds for the Profile and list leaves the newer one
in place and counts as saved. `pendingUnsubscribe(snapshot, connection, { identity, message, epoch })` finds
the newest request the Outbox holds for the list with that Mailing List
Identity, or, for a list without one, for that message, so two lists sharing an
address never take each other's state. It looks only at the connection's
current incarnation (`epoch`): a request from before the mailbox was removed and
added again is refused, and never tried again for the new one: the reader passes
the incarnation it confirmed for (`epoch` in the admission's source), and a
connection added again since refuses it. `outbox.delivered(id)` says when one
that left was confirmed and, for a request confirmed this session, to whom, even
after the capped Sent history forgets it. `outbox.emailedUnsubscribe(connection,
{ profile, message })` says the same of a request confirmed this session in that
Mail Profile for that message, so a reader that never saw the request's
identifier, as after a relaunch, still shows it sent.

| Result                      | When                                                                                                                  |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `{ kind: 'waiting', id }`   | The request waits in the Outbox as `id`, which Undo takes, or an unknown request it would try again was sent as `id`. |
| `{ kind: 'receive-only' }`  | The connection is an IMAP connection without SMTP, which receives only. Nothing is sent.                              |
| `{ kind: 'authorization' }` | The connection must be signed in again before it can send. Nothing is sent.                                           |
| `{ kind: 'failed' }`        | The connection is gone or its IMAP server lists no Sent folder yet, or storage refused the request. Nothing is sent.  |

`receive-only` and `authorization` are not failures, so the reader can say why
the connection cannot send.

## Remembering a sent request

`createUnsubscribe(native, registration)` returns the host's `unsubscribe`.
Its `request(profile, offer)` sends the request as above and, when it ends
`sent`, records it for `profile`, the Mail Profile that owns the receiving
connection, and for the Product Account signed in when the request started: the
Mailing List Identity, the list's name and the time it was sent, and for a
`mailto:` request the address it was emailed to, so a reopened message says
where it went and that it is in Sent. The record holds no unsubscribe URI,
other header value or request body. A later request
to the same list from that Profile replaces the earlier one. `failed` and
`uncertain` record nothing, nor does an offer without a Mailing List Identity or
an answer that arrives after another account signed in.

`sentRequest(profile, offer, receivedAt)` returns the Profile's record for the
offer's Mailing List Identity while a message the list sent at `receivedAt` is
at most 14 days (`unsubscribeOfferReturnsAfter`) newer than the request, so the
reader can show it as sent on that date. After that, for another Profile or for
an offer without a Mailing List Identity, it returns nothing and the message offers Unsubscribe again, as
[ADR 0044](adr/0044-isolate-standards-based-unsubscribe-actions.md) allows.

`record(account, request)` records a confirmed `mailto:` request the same way,
for `account`, the Product Account that admitted it, and only while that account
is signed in and owns the stored records; Undo and a refusal record nothing.

Native code keeps the records in `unsubscribe-requests.enc`, a document sealed
for the signed-in Product Account like its Pins and removed by an account purge.
They stay on the device: never logged, sent to Convex or included in Product
Sync. A write storage refuses leaves the outcome as it was, and a record that
cannot be read, belongs to another account or is locked reads as not sent, so
neither shows a false Sent state.

## The Mac reader

A message with a one-click offer shows the Unsubscribe banner under its header
(`apps/macos/src/unsubscribe.tsx`), and the reader's More menu (⋯) adds
**Unsubscribe…**; a `mailto:` offer shows both too. The banner names the list. The approved frame's count line (how many
messages the list sent and how many were opened) is left out until
[#2978](https://github.com/unwired-dev/product/issues/2978) defines it.

**Unsubscribe…** opens a confirmation popover that names the list, the sender
and the receiving address, or for a `mailto:` offer the address it emails, the
receiving address and that the email appears in Sent: from the banner's button, or, from the menu, below the
toolbar's More group, since the banner may be scrolled out of view. Each reader
window keeps its own confirmation, which closes once a request was sent. **Cancel** sends
nothing. **Unsubscribe** calls `unsubscribe.request` once, for the window's Mail
Profile, which owns the receiving connection. The banner then shows the outcome:

| Outcome     | Banner                                                                                                |
| ----------- | ----------------------------------------------------------------------------------------------------- |
| `sent`      | **Unsubscribe request sent**, dated, with no action. It never says that mail has stopped.             |
| `failed`    | **Couldn’t send the request**, with **Try Again** and, for a plain sender address, **Block Sender…**. |
| `uncertain` | **No clear answer to the request**, with the same actions.                                            |

**Try Again** sends once more without asking again. Until `sentRequest` has
answered, which it does again each time the message opens, and while a request is under way, the buttons are disabled and the
menu item is absent; it is gone once a request has ended. Each message's state
lives outside the reader, keyed by Product Account, Mail Profile, connection and
message, so a result that arrives after the reader moved on
changes only the message it was sent from. A request the Profile sent to the
list (`sentRequest`) within 14 days before the message arrived shows as sent on
the date it was sent. A sent request with no Mailing List Identity, or one
storage refused to record, still shows as sent for the rest of the session.

A `mailto:` request goes through `outbox.unsubscribe` instead, from the
receiving connection only. The banner shows the request the Outbox holds for the
message, also after a relaunch, then the dated Sent state once the Outbox
confirmed it. A confirmed or recorded request wins over an older attempt that
is still in the Outbox with an unknown delivery:

| State         | Banner                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Waiting       | **Unsubscribe request waiting to send**, with the countdown, the two addresses and no action. The reader's Undo Send toast offers **Undo**, which returns the banner to the offer. Once the window ends the countdown gives way to “Sending to …”.                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Sent          | **Unsubscribe request sent**, dated, saying the email is in Sent.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                         |
| Refused       | **Couldn’t send the request**, as for one-click. **Try Again** admits the retry, then takes the refused request out of the Outbox; a retry not admitted leaves it.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                        |
| Unknown       | **No clear answer to the request**, as for one-click.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                     |
| Needs sign-in | In place of **Unsubscribe…**, why the connection cannot send and **Sign In…**, which asks its provider again; an IMAP connection's password is entered in its mailbox settings. A connection that needs authorization has no open Inbox, so the reader shows this when the provider refused the request until sign-in; a **Sign In…** that completes (`authorizeMailbox` resolves true only once the account is connected and the connection no longer needs authorization) sends the refused request again, which a provider still refusing turns back into this banner, and a cancelled one leaves it; opening an IMAP connection's mailbox settings takes the refused request out of the Outbox and the offer returns. |
| Receive-only  | In place of **Unsubscribe…**, that the IMAP connection has no outgoing server and that Unwired never uses another address, with **Mailbox Settings…**.                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                    |

The waiting toast shares the reader's toast place with a saved attachment's
toast; each clears only its own. After the toast ends, the Outbox row keeps the
waiting request's **Undo**. The
Mac's ⌘Z undoes organizing only, not a send, so the frames' note that ⌘Z undoes
the request waits for a Mac Undo Send shortcut.

## Verification

```sh
mise exec -- pnpm --dir packages/mail-core exec vitest run test/unsubscribe.test.ts test/unsubscribe-mailto.test.ts
```

The tests open a message from synthetic Gmail, Graph and IMAP mailboxes and
cover each offer, refusal, list name and identity, how a native answer becomes
an outcome, and which outcomes are recorded and for how long.
`test/unsubscribe-mailto.test.ts` sends a `mailto:` request from synthetic
Gmail, Graph and IMAP connections and covers Undo, a refused handoff and
connections that cannot send, and that the Outbox records a confirmed request
(sent or filed, and found by Check Again) but not one undone or refused. On the Mac,
`apps/macos/test/unsubscribe.test.tsx` opens a synthetic Gmail message in the
reader and covers the banner, the menu item, Cancel, one request per
confirmation, each outcome, Try Again, the dated Sent state with the lookup's
Profile and arrival time, the disabled state until that lookup answers, a late
result after the reader moved to another message.
`apps/macos/test/unsubscribe-mailto.test.tsx` opens a synthetic iCloud Mail
message whose offer is `mailto:` through the real Outbox and covers the
confirmation, the waiting banner and toast, the sent request in SMTP and the
dated banner and its record, the toast's Undo, the Outbox row's Undo without
Edit, the needs-sign-in banner after the server refuses the request, and the
receive-only banner:

```sh
mise exec -- pnpm --dir apps/macos exec jest test/unsubscribe.test.tsx test/unsubscribe-mailto.test.tsx
```

A Mac native journey of the `mailto:` confirmation and waiting state is
deferred: the synthetic native mailboxes offer no `mailto:` Unsubscribe, and
adding one changes fixtures that other suites count. For #2968 a local capture
journey over temporary fixtures took the confirmation, waiting, sent,
needs-sign-in and receive-only states in Light and Dark on macOS 27.2 for the
design judge; it is not part of the committed suite.

The native tests cover the request bytes, redirects and every outcome,
including a loopback HTTPS server that takes the request and never answers:

```sh
cd native/private-inbox && swift test --filter 'oneClick|remoteContent'
```

The hosted storage suite covers the sealed `unsubscribe-requests.enc` document
(`unsubscribeRequestsStayEncryptedWithTheirProductAccount`):

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer mise exec -- zsh native/private-inbox/integration/test.zsh ios
```
