---
'@private-email/mail-core': patch
'@private-email/mobile': patch
---

Gmail's usage limit (a 429, or a 403 for a daily or rate limit) now pauses a Gmail Inbox's synchronization instead of retrying at once: until the time Gmail named, or after a wait that grows with each limit in a row, keeping saved mail and changes made meanwhile. The Gmail Inbox state reports the pause as `limit`, with Gmail's time and the day's count. On iPhone and iPad the Sync Status capsule says **Gmail paused** with that time, and the connection's details keep **Try Again** unavailable until it (#2488).
