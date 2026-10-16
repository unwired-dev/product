---
'@private-email/mail-core': patch
---

A reader whose inline images waited for the shared display budget now shows them as soon
as any Gmail or IMAP reader frees it, without reopening: closing a Gmail reader admits a
waiting IMAP window, closing an IMAP window admits a waiting Gmail reader, and a Gmail
reader of another message takes the budget a closing Gmail reader held. Readers that were
not held back keep their presentation. Removing a Gmail message from the cached views or
refreshing it to a smaller presentation or hiding Remote Message Content also returns its
display budget to waiting inline images.
