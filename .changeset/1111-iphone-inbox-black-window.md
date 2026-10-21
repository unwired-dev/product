---
'@private-email/mobile': patch
---

Show the connected Inbox on iPhone again. Since Settings moved onto a native stack
above the Inbox, the Inbox opened as an entirely black window after setup and on
later launches. It now waits for its stack screen to join the window before
mounting the split view, so the Mailboxes, list and reader appear.
