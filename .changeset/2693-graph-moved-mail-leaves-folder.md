---
'@private-email/mail-core': patch
---

A Microsoft message archived, deleted or moved out of the Inbox or another folder now leaves that folder's list. Graph reads a message by its ID wherever it is now, so a delta change is checked against the folder Graph names for it; before, the message stayed listed in its old folder after the move, after relaunch and after a refresh (#2693, part of #637).
