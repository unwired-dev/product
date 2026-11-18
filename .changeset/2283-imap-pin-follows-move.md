---
'@private-email/mail-core': minor
---

An IMAP message's Pin follows it across a move and its Undo to the UID the server reported, keeping its date; where the server reports none, the Pin is removed instead of being left under the old ID. The Pins store adds `move` (#2283, part of #2084).
