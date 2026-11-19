---
'@private-email/mail-core': minor
---

IMAP invitation responses can go through the Outbox: `imapInvitationResponses` admits an Accept, Maybe or Decline to the Outbox from the invited IMAP mailbox, where it waits out the Undo Send Window (`waiting`, then `queued`) and **Undo** takes it back without creating a Draft. The Outbox's new `respond` hands it to SMTP once and files its Sent copy; when the mail server accepts it, the response is recorded in the mailbox's cache, which the IMAP Inbox's new `recordResponse` and `responses` keep, so it shows after relaunch. A refusal reads as **Not sent** and the next choice replaces it; an unconfirmed handoff stays **Delivery unknown** and is never resubmitted, and **Check Again** looks for it in Sent. Outbox entries carry the response's invitation in `invitation`. No client shows these states yet (#2439, part of #1279).
