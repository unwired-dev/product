---
'@private-email/mobile': patch
'@private-email/macos': patch
---

Count composer recovery records in the Outgoing Content Store's 100 MB (#2054, part of #1989). A record that would exceed it is refused and leaves the record it would replace, and a Draft save or attachment is refused when records leave too little space.
