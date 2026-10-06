---
'@private-email/mail-core': patch
---

Limit message link actions to 200 in rich, plain and fallback readers while
preserving later text. Normalize repeated breaks, preformatted newlines and
empty linked spacers so hidden suffixes cannot mask the visible link label.
