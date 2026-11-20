---
'@private-email/mail-core': patch
---

An IMAP invitation response the mail server accepted keeps reading as sending until it leaves the Outbox, while it files its Sent copy and records the response, so the cards on Mac, iPhone and iPad keep Accept, Maybe and Decline unavailable instead of offering a choice that would be ignored (#2470, part of #1279).
