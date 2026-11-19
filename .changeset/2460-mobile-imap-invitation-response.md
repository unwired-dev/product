---
'@private-email/mobile': patch
---

On iPhone and iPad, an invitation in an IMAP mailbox that can send offers **Accept**, **Maybe** and **Decline**: the response waits in the Outbox for the Undo Send Window with **Undo** and **View in Outbox**, then goes through the mailbox's own mail server, and the card names that server when it accepts, refuses or doesn't confirm the response. **View in Outbox** ends a search and shows the Outbox at the top of the message list. The Outbox shows the response in its own row with its meeting, choice and status, **Undo**, **Check Again** and **Open Invitation**, and no Edit (#2460, part of #1279).
