---
'@private-email/mail-core': patch
---

A Pin whose relocation after an IMAP move Pin storage refused, as while the device is locked, now follows its message once storage accepts writes again: the IMAP cache keeps the move, also one answered while access closed, and the Inbox repeats it in order each time it opens, also after relaunch. The IMAP Inbox's `relocated` option now resolves whether the move was kept (#2340, part of #2084).
