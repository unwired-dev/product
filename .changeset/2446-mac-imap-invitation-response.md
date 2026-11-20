---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
---

On the Mac, an invitation in an IMAP mailbox that can send offers **Accept**, **Maybe** and **Decline**: the response waits in the Outbox for the Undo Send Window with **Undo** and **View in Outbox**, then goes through the mailbox's own mail server, and the card names that server when it accepts, refuses or doesn't confirm the response. The Outbox shows the response in its own row with its meeting, choice and status, **Undo**, **Check Again** and **Open Invitation**, and no Edit. `invitationResponding` takes an IMAP mailbox's `server` from the new `imapServer`, and `outboxCopy` words an Invitation Response's status as a response (#2446, part of #1279).
