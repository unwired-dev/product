---
'@private-email/localization': patch
'@private-email/mail-core': patch
'@private-email/mobile': patch
---

On iPhone and iPad, **Edit** in Mailboxes, beside Account on iPhone and the sidebar toggle on iPad, lets Favorites show or hide each row and reorder them until **Done**; All Inboxes stays shown. The rows are the Profile's synchronized Inbox preference the Mac already edits, hiding the selected Unified Mailbox selects the first row still shown, and the Command Palette opens each Unified Mailbox, leaving a reader or composer that covers the list first, and, while the iPad sidebar shows, Edit Favorites (#2611, part of #2106). `sidebarCommands` takes `unified` as optional, as it takes `favorites`.
