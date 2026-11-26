# Unsubscribe

[#2060](https://github.com/unwired-dev/product/issues/2060), the first slice of
[#654](https://github.com/unwired-dev/product/issues/654), finds the
[Unsubscribe Suggestion](domain/organization.md) an opened message offers, and
[#2077](https://github.com/unwired-dev/product/issues/2077) sends its one-click
request, [#2823](https://github.com/unwired-dev/product/issues/2823) remembers each
request that was sent, and [#2824](https://github.com/unwired-dev/product/issues/2824)
sends a `mailto:` request through the Outbox.
[#2967](https://github.com/unwired-dev/product/issues/2967) adds the Mac reader's
banner, confirmation and outcomes for one-click offers; the `mailto:` states
follow in [#2968](https://github.com/unwired-dev/product/issues/2968), under
[ADR 0044](adr/0044-isolate-standards-based-unsubscribe-actions.md).

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

`outbox.unsubscribe(connection, offer)` admits a `mailto:` offer's request once,
after the person confirms it. `connection` is the Mailbox Connection that
received the message. The request is an ordinary message from that connection's
address to the offer's one address, with only the offer's `subject` and `body`:
no Cc, Bcc, reply headers or other `mailto:` fields. Each line of the body is a
paragraph. It is never a Draft, so it never syncs.

It waits in the Outbox under the Undo Send Window and is then claimed and sent
like any message, so it appears in the connection's Sent mailbox and an
uncertain handoff is never sent again automatically. Undo, or Edit after a
refusal, only takes it out of the Outbox. Nothing logs the address, subject or
body, and Convex hears only the claim's opaque identifier.

| Result                      | When                                                                                                                 |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `{ kind: 'waiting', id }`   | The request waits in the Outbox as `id`, which Undo takes.                                                           |
| `{ kind: 'receive-only' }`  | The connection is an IMAP connection without SMTP, which receives only. Nothing is sent.                             |
| `{ kind: 'authorization' }` | The connection must be signed in again before it can send. Nothing is sent.                                          |
| `{ kind: 'failed' }`        | The connection is gone or its IMAP server lists no Sent folder yet, or storage refused the request. Nothing is sent. |

`receive-only` and `authorization` are not failures, so the reader can say why
the connection cannot send.

## Remembering a sent request

`createUnsubscribe(native, registration)` returns the host's `unsubscribe`.
Its `request(profile, offer)` sends the request as above and, when it ends
`sent`, records it for `profile`, the Mail Profile that owns the receiving
connection, and for the Product Account signed in when the request started: the
Mailing List Identity, the list's name and the time it was sent. The record
holds no unsubscribe URI, other header value or request body. A later request
to the same list from that Profile replaces the earlier one. `failed` and
`uncertain` record nothing, nor does an offer without a Mailing List Identity or
an answer that arrives after another account signed in.

`sentRequest(profile, offer, receivedAt)` returns the Profile's record for the
offer's Mailing List Identity while a message the list sent at `receivedAt` is
at most 14 days (`unsubscribeOfferReturnsAfter`) newer than the request, so the
reader can show it as sent on that date. After that, for another Profile or for
an offer without a Mailing List Identity, it returns nothing and the message offers Unsubscribe again, as
[ADR 0044](adr/0044-isolate-standards-based-unsubscribe-actions.md) allows.

Native code keeps the records in `unsubscribe-requests.enc`, a document sealed
for the signed-in Product Account like its Pins and removed by an account purge.
They stay on the device: never logged, sent to Convex or included in Product
Sync. A write storage refuses leaves the outcome as it was, and a record that
cannot be read, belongs to another account or is locked reads as not sent, so
neither shows a false Sent state.

## The Mac reader

A message with a one-click offer shows the Unsubscribe banner under its header
(`apps/macos/src/unsubscribe.tsx`), and the reader's More menu (⋯) adds
**Unsubscribe…**. A message whose only offer is `mailto:` shows neither until
#2968. The banner names the list. The approved frame's count line (how many
messages the list sent and how many were opened) is left out until
[#2978](https://github.com/unwired-dev/product/issues/2978) defines it.

**Unsubscribe…** opens a confirmation popover that names the list, the sender
and the receiving address: from the banner's button, or, from the menu, below the
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

## Verification

```sh
mise exec -- pnpm --dir packages/mail-core exec vitest run test/unsubscribe.test.ts
```

The tests open a message from synthetic Gmail, Graph and IMAP mailboxes and
cover each offer, refusal, list name and identity, how a native answer becomes
an outcome, and which outcomes are recorded and for how long.
`test/unsubscribe-mailto.test.ts` sends a `mailto:` request from synthetic
Gmail, Graph and IMAP connections and covers Undo, a refused handoff and
connections that cannot send. On the Mac,
`apps/macos/test/unsubscribe.test.tsx` opens a synthetic Gmail message in the
reader and covers the banner, the menu item, Cancel, one request per
confirmation, each outcome, Try Again, the dated Sent state with the lookup's
Profile and arrival time, the disabled state until that lookup answers, a late
result after the reader moved to another message and a `mailto:`-only message:

```sh
mise exec -- pnpm --dir apps/macos exec jest test/unsubscribe.test.tsx
```

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
