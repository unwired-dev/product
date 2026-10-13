---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Add the Command Palette to the Mac, iPhone and iPad clients. It finds and runs
the open message's actions (Reply, Reply All, Forward, read state, Star, Archive,
Trash, Spam and Move to… with its picker), New Message, Search Mail, Inbox and
Account, with fixed ordering and fuzzy matching. The Mac keeps a command input
at the top of each window and opens with View › Commands… (Command-P), Up and
Down, Return and Escape; iPhone opens by a header swipe on the Inbox heading,
the reader's subject line or the composer's top bar, which now stay put while
the content scrolls, with a one-time hint and an accessibility action; iPad also
keeps the input in those headers.
