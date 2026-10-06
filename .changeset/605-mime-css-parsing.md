---
'@private-email/mail-core': patch
---

Preserve message text when MIME headers contain charset decoys, and prevent
inline-image downloads from hidden CSS escapes or internally spaced Content-IDs.
