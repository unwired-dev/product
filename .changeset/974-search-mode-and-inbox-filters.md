---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
---

Redesign search on iPhone and iPad: focusing the search field opens a search mode with Close Search beside the field, results under Top Results with the query's words marked in each sender and subject, and, in a single mailbox or folder, an All Mailboxes / Current Mailbox choice. Editing or clearing the query keeps search open instead of flashing back to the Inbox. A new Filter button narrows the Inbox to unread mail, mail from today or chosen mailboxes through the Filters sheet, and shows what the Inbox is filtered by. `matchedRanges` in `mail-core` finds where a query's words appear in a field, matched as search matches them.
