---
'@private-email/mobile': minor
'@private-email/mail-core': patch
---

On iPhone and iPad, a message sent just before switching apps or locking the device finishes its Undo Send Window and reaches its provider within the background time iOS grants; otherwise it stays queued with its original deadline until the app is active again.
