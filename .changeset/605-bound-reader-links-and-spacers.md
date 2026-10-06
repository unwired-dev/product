---
'@private-email/mail-core': patch
---

Limit message link actions to 200 in rich, plain and fallback readers while
preserving later text. Normalize repeated breaks, preformatted newlines and
empty linked spacers so hidden suffixes cannot mask the visible link label.

Preserve IPv6 host brackets and balanced URL-path delimiters when detecting
plain-text links, while keeping surrounding sentence punctuation outside the link.
