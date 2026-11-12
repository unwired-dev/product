---
'@private-email/mail-core': patch
---

Render HTML mail with the sender's phone layout: admit sanitized `max-width` media
rules for geometry and type, keep a link-only cell's background with a contrasting
label, keep words whole, and let long URLs wrap at their punctuation.
