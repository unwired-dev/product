---
'@private-email/convex': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
'@private-email/macos': patch
---

Deleting a Product Account no longer leaves the device stuck on **Confirm account
deletion** when Apple refuses the deletion's authorization. Convex now answers that
refusal as an aborted deletion that kept the account, instead of an unknown server
failure, and the device returns to the account, saying nothing was deleted, even
after an earlier attempt whose reply was lost.
