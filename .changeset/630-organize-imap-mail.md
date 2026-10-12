---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Organize, search and refresh IMAP mail. Messages from iCloud Mail, Fastmail and other
IMAP servers can be marked read or unread, archived, moved to Trash or Spam (the
folders the server declares by role), moved to any other folder, and moved back with
Undo. Changes are saved on the device and sent to the server in order, surviving
outages and relaunch; COPY fallback records its destination before deleting the source. An uncertain
move without that record waits for explicit discard and is never replayed. A message
another client moved, a recreated folder, a changed role mapping or a removed destination
shows as the server has it. Servers without MOVE or UIDPLUS offer only read state.

Online search also asks each IMAP server, covering up to 50 folders including the Inbox
without Trash and Spam, and says when folders or older matches were left out. Its copy
no longer names Gmail. IMAP servers that advertise IDLE report new mail while the Mac
app runs and while the iPhone or iPad app is active.
