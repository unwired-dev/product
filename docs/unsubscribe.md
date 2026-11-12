# Unsubscribe

[#2060](https://github.com/unwired-dev/product/issues/2060), the first slice of
[#654](https://github.com/unwired-dev/product/issues/654), finds the
[Unsubscribe Suggestion](domain/organization.md) an opened message offers. The
reader banner, confirmation and outcomes, the isolated one-click request and
`mailto:` delivery through the Outbox follow in later #654 slices, under
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
  HTTPS address with user information or without a valid host and port,
  unbracketed URIs, several `mailto:` addresses and undecodable escapes.

URIs must be in angle brackets; whitespace inside the brackets is ignored, as
RFC 2369 asks, and a bracketed URI inside a comment is not one. Field names and
values are percent-decoded. The offer names the list by the `List-Id` phrase,
such as `Alza.cz newsletter` in `Alza.cz newsletter <newsletter.alza.example>`,
else by the sender's display name or address. With no name at all there is no
offer.

The check is syntactic. It does not verify that a DKIM signature covers the
list headers, so the confirmation names the list and the receiving address, and
the later request boundary will reject non-public destinations
([ADR 0044](adr/0044-isolate-standards-based-unsubscribe-actions.md)). Header
values stay on the device: they are never logged, sent to Convex or included in
Product Sync.

## Verification

```sh
mise exec -- pnpm --dir packages/mail-core exec vitest run test/unsubscribe.test.ts
```

The tests open a message from synthetic Gmail, Graph and IMAP mailboxes and
cover each offer, refusal and list name.
