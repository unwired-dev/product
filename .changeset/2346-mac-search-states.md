---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/macos': patch
---

On the Mac, a search that matches nothing shows the **No Results** empty state, naming the scope and the query, and the subtitle reads "No results · Travel" for the searched folder or mailbox; while the mail servers are searched, skeleton rows hold their answer's place and the subtitle names the mailboxes searched, as in "Searching All Inboxes…" (#2346, part of #2090). A Unified Mailbox now reports `unlisted` while a mailbox is opening or a folder has listed nothing yet because its first listing is still to arrive or failed. `inboxUnlisted` says whether a mailbox has listed its Inbox yet.
