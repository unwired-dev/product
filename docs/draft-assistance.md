# On-device Draft rewrites, Writing tools and reply suggestions

Setup, coding rules, validation and observable requirements remain in this file.

[#621](https://github.com/unwired-dev/product/issues/621) adds explicit
[Compose and Response Assistance](domain/assistance.md) to the composer on iPhone,
iPad and Mac: a meaning-preserving rewrite of authored Draft text, and one
suggested reply for a Reply or Reply All Draft. Both run on Apple's on-device
system language model. There is no cloud or product-backend model fallback.
[#1616](https://github.com/unwired-dev/product/issues/1616) adds the Mac
composer's other Writing tools that edit authored text the same way, and
[#1623](https://github.com/unwired-dev/product/issues/1623) adds them to the
iPhone and iPad composer, and
[#1625](https://github.com/unwired-dev/product/issues/1625) adds the Mac
composer's **Generate a Draft…**, which writes new text from a prompt.

## Behavior

- **Rewrite** sits in the format bar's **Writing tools** (sparkles) menu with the
  other actions listed below, which is unavailable while sending. With text
  selected it rewrites the selection; with nothing selected it rewrites the whole
  authored body. It is disabled while that text is blank.
- The Writing tools menu groups its items as the approved design does:
  **Rewrite** and **Suggest reply** (on Mac led by **Generate a Draft…**);
  **Proofread** and **Break into Paragraphs**; **Translate** (**Translate To** on
  Mac); **Expand Text** and **Shorten Text**; **Make More Friendly** and
  **Make More Neutral**. Each of these text tools captures text and is enabled like
  **Rewrite**, and its review panel carries its own title. **Proofread** corrects
  only spelling, grammar and punctuation; **Break into Paragraphs** only splits the
  text into paragraphs; **Expand Text** and **Shorten Text** change its length;
  the tone tools change only its tone. The `registration-draft-editor` evaluation
  editor still offers only **Rewrite** on iPhone and iPad.
- On Mac, **Generate a Draft…** needs no text, so it is enabled whenever the
  menu is. It opens a popover below the menu button with a prompt field and
  **Generate**, which is disabled while the prompt is blank; Return also
  generates. The close button, Escape or a click elsewhere dismisses it without
  changing the Draft. The model reads only the prompt, never the Draft, and the
  result opens in the review panel titled **Generated draft**. **Insert** places
  it at the caret, after any selection without replacing it, as one undoable
  edit; **Discard** closes it. A prompt longer than the input bound is refused
  before the model is asked. Changing the Draft's Profile dismisses any unfinished
  prompt, even when the destination also permits assistance. Prompts are not kept,
  so the design's prompt-history control is not offered.
- **Suggest reply** appears only in a Reply or Reply All Draft that has its quoted
  message. It writes one complete reply that keeps the points already written.
- Choosing either action is the request: it captures the text and opens a review
  panel with progress and **Cancel**. Nothing runs before that.
- A rewrite, like every text tool, reads only the captured authored text. A reply suggestion reads only
  the authored body, the display names of the To and Cc recipients and the Draft's
  already-local quoted message. It never reads recipient address fields, Bcc, the
  subject, attachments or Inline Images, and drops every word containing "@" from
  the names and quoted text. Any word cut at the input bound is dropped too,
  so no raw address or address fragment, such as the sender in the quoted
  attribution line, reaches the model. It never fetches mail, makes no Gmail
  request and never sends.
- Recipient context considers at most the first 100 To/Cc recipients, in To-then-Cc
  order, including recipients without display names. Their names use a
  500-character prefix, including separators. Later names may be omitted even
  when that prefix has room. Names and quoted text are each bounded before
  addresses are removed; removing addresses does not extend either prefix.
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
- On Mac, a finished Writing tools result (Rewrite, Proofread, Break into
  Paragraphs, Expand, Shorten and the tones) is checked mechanically against the
  captured text, using `checkDetails` from the assistance core. It never says a
  result is verified or safe: every finished result ends with a note that the
  checks compare details only and that meaning, questions and commitments need
  the person's own reading. Reply suggestions and Generate a Draft are not checked.
  - Checked details are links (written web addresses, with a scheme or as a
    bare domain such as `example.com/r` or `example.com:8080/r`, and the destination of linked words
    whose text does not show it exactly), email addresses (including
    `mailto:` links without query fields; mail links with query fields remain
    flagged with their complete destination), amounts (a number with a currency
    symbol, a three-letter code or Kč, including compact `USD40` and `40USD`,
    combined `$40USD` and a sign after the code in `USD-40`), numbers with their sign or leading decimal
    point (`-40`, `.5`),
    dates in any letter case, times and quoted text in straight, curly, low
    and angle quotes.
  - A detail is kept only when the result writes an unambiguous equivalent: the
    same text apart from spacing, letter case for email addresses, dates and
    times (`8 P.M.` and `8pm`), the currency on either side of an amount
    (`40 €` and `€40`), the quote style around the same quoted words, and
    a full stop, comma, colon, semicolon or closing quote after a written link
    (`example.com/r.`), which is not part of it. `!` and `?` can end an address,
    so they stay part of the link, and a linked word's own destination decides
    even when its text shows the address with such punctuation. Its complete
    address must be written out; a substring is insufficient. Written linked
    text may omit the web scheme or root slash, but a slash after a path stays
    part of the destination. A number beside a unit (`0.5s`, `3rd`) is compared by its figures. Nothing
    else is interpreted, so `3` rewritten as `three` is removed.
  - A difference that may be another way to write the same detail is
    uncertain, never kept: a date that gains or loses a part (`Saturday` as
    `Saturday, 1 Nov`) or is in figures on one side only (`2026-11-01` as
    `1 November 2026`), a number or amount that differs only by a thousands
    separator (`1,000` as `1000`), and a link that differs only by `!` or `?`
    at its end. Any other pair, such as `Monday` as `Tuesday` or `.5` as `5`,
    is changed.
  - Details that differ are paired in order within each kind as changed, and
    the rest are removed or added. The panel counts them, lists each with its
    original and rewritten value (a changed link says it goes somewhere else; an
    uncertain one says it can't be confirmed as the same date, number, amount
    or link) and lists the
    kept details. The apply action then becomes **Use rewrite with changes**,
    so applying them is an explicit choice; **Keep original** and **Try again**
    stay. A checked result's actions are push buttons in the frames' order: the
    accent tint marks **Keep original** when details differ and **Replace text**
    when none do. The accent button is the window's default button: Return presses it
    unless the focused view takes the key, as the Draft body does for a new
    line. VoiceOver reads each row as one element and hears the count after
    the result.
- A result belongs to the text it was captured from. Any edit to the Draft body, or to the To/Cc recipients
  or quoted text used for a reply, cancels a pending request and closes its review, so a stale result is never
  offered or applied. Closing the Draft cancels the request. Controls rendered for
  an earlier state cannot affect a replaced or closed one.
- Send closes any assistance preview and cancels its pending request. Rewrite and
  Suggest reply wait while Send is pending and become available again if it is refused.
- When the model cannot run, the Draft is unchanged and the panel says why, with
  the same reasons as [message summaries](message-summaries.md#behavior). A
  refusal, cancellation and other failures have their own messages. **Try again**
  is offered except on an ineligible device, after a refusal, or for text in a
  language the model cannot write.
- A rewrite or other text tool keeps the language of the authored text and adds
  nothing it does not contain: no subject line, greeting, sign-off or signature. When the model cannot
  write that language, the panel says writing help is not available in this
  language and the Draft is unchanged. A reply suggestion is written in the
  language of the message answered
  ([#1164](https://github.com/unwired-dev/product/issues/1164)).

Not in this slice: the three concise reply directions and the question check that
[Response Assistance](domain/assistance.md) describes, subject suggestions,
and **Generate a Draft…** on iPhone and iPad.
The Writing tools that use the model appear only
while [Mail Assistance Enablement](message-summaries.md#mail-assistance-enablement)
is on; turning it off cancels a pending request and closes its panel.

## Native binding

The methods are on the `UnwiredAssistance` module in
`native/private-inbox/bridge/UnwiredAssistance.swift`, which both hosts compile, so
no setup step is needed. Each checks availability like `summarize` and rejects with
the same codes.

| Method                         | Result                                                  |
| ------------------------------ | ------------------------------------------------------- |
| `rewrite(request, input)`      | The edited or generated text, in the input's language   |
| `suggestReply(request, input)` | The reply body, without a subject, signature or quoting |
| `cancel(request)`              | Cancels that request's generation                       |

The shared core supplies `input` as a typed JSON request with an explicit
`operation`: each text tool (`rewrite`, `proofread`, `paragraphs`, `expand`,
`shorten`, `friendly` or `neutral`) carries `authoredText` and goes to `rewrite`,
which gives the operation its own instructions; `generate` carries only the
trimmed `prompt` and also goes to `rewrite`, which writes the email text the
prompt describes from its facts alone, without a subject or signature; `reply` carries separate
`recipientNames`, `authoredText` and `quotedText` fields. Labels and field names
inside correspondence remain escaped content within their field. The 6,000-character
limit counts the complete encoded request. Authored text is preserved in full or
the request is refused; only quoted context can be shortened.

Each prompt treats its input as untrusted content, never as instructions, and forbids
inventing facts. The rewrite prompt holds even for short text that reads like a
request: before #1164, `test` with one Czech line came back as a new message with
`Subject: Test - Please Expand This Message`. A rewrite names its language like a
[summary](message-summaries.md#native-binding): the binding identifies the
language of `authoredText`, or of `prompt` for a generated draft, rejects one the model does not support, or a result in
another language, as `unsupported-language`, and otherwise tells the model to
respond in it. Reply suggestions keep their own rule to answer in the language of
the quoted message. Generation uses temperature 0 and at most 1,500 response tokens.
`@private-email/mail-core/assistance` decodes every result with Schema (up to
12,000 characters) and fails closed on anything else. Results containing image
placeholder characters are rejected, keeping the Draft unchanged rather than
applying text the editor would drop. Failure logs carry only the
allow-listed native code or decode path, never Draft or generated text.

## Deterministic evidence

- `packages/mail-core/test/assistance-input.test.ts` checks that reply input and
  Draft capture stop at the recipient-entry bound, including address-only lists.
- `packages/mail-core/test/assistance.test.ts` covers the admitted reply context
  (names and quoted text without addresses, the quoted message without images, the input bound and
  its disclosure, delimiter spoofing and JSON escaping), refused authored text and the distinction between
  encoded reply overflow and unusable quoted context, routing to `rewrite` or `suggestReply`,
  each text tool's operation and refusals, a prompt-only `generate` request
  inserted after a selection and its blank and too-long prompts,
  refusal, unavailability and failure without logging Draft text, retry rules, an
  oversized result, cancellation with a late result, and Mock Mail Session outcomes.
- `packages/mail-core/test/draft-details.test.ts` checks the detail rules: kept,
  changed, uncertain, removed and added details of each kind, the accepted equivalents,
  `3` and `three`, regrouped numbers, signed and leading-decimal numbers and
  amounts, decimals beside a unit, reformatted dates and quotes, dates and
  ordinals in capitals, bare addresses,
  trailing link punctuation including `!`, and hidden, scheme-less and
  `mailto:` link destinations, including address substrings, path slashes and
  mail links with query fields.
- The composer tests in `apps/mobile/test/composer.test.tsx` and
  `apps/macos/test/composer.test.tsx` rewrite the whole body and a selection,
  check the Writing tools groups, symbols and per-tool requests, panels and Replace,
  the Mac Generate a Draft popover's blank prompt, Close and Escape, its prompt-only
  request, Cancel, Insert at the caret with Undo, Discard and a too-long prompt,
  review and apply the whole-body result as one undoable edit without touching recipients, keep the
  original against a queued apply, show reply-length guidance without inference when the encoded authored
  reply leaves no room for context, show a refusal, cancel and retry, and drop a
  pending result when the body is edited or the Product Account changes. The Mac tests also show the
  details note on every rewrite, and a rewrite with changed details: its count and announcement, one
  readable row per change, the kept details, no plain Replace, Keep original, then **Use rewrite with
  changes** and Undo. From the real reader with a synthetic
  Gmail mailbox, they request a reply suggestion for a Reply All Draft, check its
  admitted input and that no Gmail request is made, apply it to the authored body
  only, undo it, invalidate recipient edits even when Undo precedes a queued apply,
  and cancel a pending request on recipient changes or by closing the Draft.
- [Mock Mail Sessions](mock-mail-sessions.md#boundaries-and-scenarios) supply fixed
  rewrite and reply outcomes. Native mock builds use the same fixed synthetic text,
  except the [assistance qualification build](assistance-qualification.md).

These are mocked journeys. They do not show that Apple's model runs or what it
writes.

## Native qualification and deferred checks

[Assistance qualification](assistance-qualification.md) has exercised the real
binding, including long input, on the nominated Mac mini M4, iPhone 17 Pro Max
and iPad Pro M4 with a versioned synthetic corpus. Generated text still needs
human review. Corpus version 4 adds
[heuristic checks](assistance-qualification.md#the-qualification-build) for
language switches and added letter framing
([#1164](https://github.com/unwired-dev/product/issues/1164)); physical iPhone and
iPad runs of it remain the owner session in
[#625](https://github.com/unwired-dev/product/issues/625).
The [owner-session results](https://github.com/unwired-dev/product/issues/625#issuecomment-6335027314)
accept Rewrite/Suggest reply with acceptance and Undo on both physical mobile
devices and waive the Mac manual checks. Each unobserved unavailable reason
remains a release check. Compilation alone is not evidence of model behavior.
