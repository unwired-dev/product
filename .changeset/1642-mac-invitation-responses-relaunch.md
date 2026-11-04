---
'@private-email/mail-core': minor
'@private-email/macos': patch
---

Keep Mac Gmail Invitation Responses across relaunch. A response is recorded in
the mailbox's encrypted cache before it is sent, so after relaunch a confirmed
response shows its choice and confirmation time, and one the app quit while
sending, or whose delivery was unknown, shows **Delivery unknown** with
**Check Again** instead of being sent again. A response that cannot be recorded
is not sent. Records hold only the invitation's UID and SEQUENCE, the choice,
the confirmation time and the MIME boundary, and leave with the mailbox. The
Gmail Inbox exports `recordResponse` and lists recorded `responses`.
