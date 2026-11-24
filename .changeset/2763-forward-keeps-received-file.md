---
'@private-email/mail-core': patch
'@private-email/macos': patch
'@private-email/mobile': patch
---

**Forward** and **Attach to New Message** keep a downloaded attachment on the device until the Draft has copied it, so a reader that closes first, as when the iPhone composer replaces it, no longer leaves the file **Not added** (#2763).
