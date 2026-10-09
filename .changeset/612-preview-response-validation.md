---
'@private-email/mail-core': patch
---

Keep malformed inline-image preview replies unavailable instead of reporting a
healthy Draft asset without image bytes. Native-only attachment verification
continues to accept its empty success reply.
