---
'@private-email/mail-core': minor
'@private-email/macos': minor
'@private-email/localization': minor
---

Block and unblock a sender on the Mac (#2141, part of #655).

- A reader's sender menu gains Block Sender…, which confirms in a sheet and blocks the sender's exact address for the window's Mail Profile.
- Settings › Blocked Senders lists each Profile's Blocked Senders, newest first, with the date blocked and how many arrivals this device moved to Trash, and − unblocks the selected one.
- `createBlockedSenders` gains `subscribe`, and `blockedSenders(profile, connections)` reports each sender's `moved` count on those connections since it was blocked, and `screen` takes the connection with whether it can move to Trash now.
