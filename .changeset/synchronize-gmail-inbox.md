---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Show the connected Gmail mailbox's Inbox on iPhone, iPad and Mac. Once setup needs nothing more, launch opens the Inbox; the Account button opens the account page, and Open Inbox returns. The first synchronization lists the Inbox newest first in pages of 50, showing each page as it arrives and keeping the newest 200 messages on the device. Later activations apply arrivals, archiving, deletions and read changes from Gmail history. Every step commits with its checkpoint in an encrypted cache, so relaunch, interruption and expired history neither lose nor duplicate messages. The cached list stays visible while Gmail is checked, when Gmail needs permission again, and when it cannot be reached. Gmail tokens stay in native code, mail metadata stays on the device, and sign-out, deletion and choosing another mailbox remove the cache.
