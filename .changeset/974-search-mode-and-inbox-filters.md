---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
---

Redesign search on iPhone and iPad: focusing the search field opens a search mode with Close Search beside the field, results under Top Results with the query's words in bold in each sender and subject, and, in a single mailbox or folder, an All Mailboxes / Current Mailbox choice. Editing or clearing the query keeps search open instead of flashing back to the Inbox. A new Filter button narrows the Inbox to unread mail, mail from today or chosen mailboxes through the Filters sheet, and shows what the Inbox is filtered by. Filters opens as a full-height sheet on iPhone and as a popover above the Filter control in a regular-width iPad window, where the floating bar spans the whole window with a centered 400pt search field. The theme adds the 18pt `radius.popover` token. `matchedRanges` in `mail-core` finds where a query's words appear in a field, matched as search matches them. The shared `filterMessages` projection applies the host's `InboxFilter` settings to validated listed metadata.
