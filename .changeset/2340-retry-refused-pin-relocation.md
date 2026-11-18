---
'@private-email/mail-core': patch
---

A Pin whose relocation after an IMAP move Pin storage refused, as while the device is locked, now follows its message once storage accepts writes again: the IMAP cache keeps the move, and the Inbox repeats it in order each time it opens, also after relaunch. A move answered while the cache itself was locked is held in memory until the cache reopens, so quitting before then loses it. The IMAP Inbox's `relocated` option now resolves whether the move was kept, and the Pins store's `move` keeps the moved Pin's date where its destination was pinned again (#2340, part of #2084).
