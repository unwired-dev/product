---
'@private-email/mail-core': minor
---

Mail-core owns how a window lists a mailbox's folder: `listedFolder` picks the chosen IMAP folder
or Gmail or Microsoft view, falls back to the Inbox and says when the choice was dropped, and
`folderListing` gives that folder's messages, title, failure notice, limits and whether it has
listed anything yet. The Mac, iPad and iPhone lists use them, with no change in what they show.
`createGmailViewEntries` is removed (#2494).
