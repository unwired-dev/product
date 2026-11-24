---
'@private-email/mobile': patch
'@private-email/macos': patch
---

**More from Mail Servers** no longer drops another mailbox's failed search. A
mailbox whose first page failed keeps its reason and **Try Again** until it is
searched again, so the online results no longer read as **No Results** when that
mailbox was never searched.
