---
'@private-email/mobile': patch
'@private-email/mail-core': patch
---

In a compact iPad window the reader shows the Command input in its navigation bar, beside Back
with the mailbox's unread count, and the composer sheet ends its From row with the input as the
command symbol alone (#2133).
Composer navigation counts the leaves it allowed, so a command waiting on a closing composer can
tell when another destination was chosen.
