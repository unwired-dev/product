---
'@private-email/mail-core': patch
---

Bound sender-controlled MIME metadata before any header is parsed: header count,
total header text, header name and value length, Content-ID length and Gmail's
MIME type. An explicit open of a message over a budget reports its body as
failed, and prefetch keeps it on demand without pausing later prefetches. Find
comment delimiters in one pass, so an unterminated quoted string no longer costs
time quadratic in the header's length.
