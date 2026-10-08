---
'@private-email/mail-core': patch
---

Keep the later edit time when concurrent storage writers save identical Draft
content, preserving its position in the newest-first Draft list after reopening.
