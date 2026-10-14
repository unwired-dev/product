---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': minor
'@private-email/mail-core': minor
---

Rebuild the app shell around a Mailboxes sidebar and a floating search bar (#900).

- **Mailboxes:** a sidebar column lists **All inboxes** and its unread count, then each Mailbox Connection with its Inbox and unread count and, for IMAP, its selectable folders, and the **Account** page last. It replaces the mailbox and folder chips above the list. On the Mac it is a floating Liquid Glass column that a toolbar button hides and shows; windows at most 900pt wide start without it. On iPad it is the leading split-view column; on iPhone it is one Back away from the Inbox.
- **Floating bar:** search and **New Message** share a Liquid Glass bar at the bottom of the message list, which rows scroll under. On iPhone and iPad the bar rises above the software keyboard while its search field is in use.
- **Command Palette:** the Mac window's command bar spans the sidebar, list and reader; the palette's **New Message** follows the floating bar's button, so it is offered only while that button is enabled, and **Search Mail** focuses the floating bar's search field. On iPhone and iPad the Mailboxes title opens the palette by a downward swipe or its accessibility action, and **Search Mail** and **Inbox** bring the message list forward.

- **Mail core:** export the shared mailbox sidebar projection through `mail-core/mailboxes`, including unread totals, selectable folders, selection, each mailbox's storage or synchronization problem, the IMAP folders whose last read failed, and authorization recovery.
- **Sidebar status:** a mailbox whose storage is locked or failed, or whose provider could not be reached or needs authorization again, shows a warning beside its Inbox row with the problem as its accessibility value, so the problem is visible while another mailbox is selected. An IMAP folder whose last read failed shows the same warning on its own row, with **Folders could not be listed** as its accessibility value, until it is read again.
- **Lapsed authorization:** a chosen mailbox whose provider authorization lapses stays chosen, showing its authorization notice and, in the heading, its authorization status, instead of falling back to **All inboxes**, so **New Message** cannot start a Draft from another sender. Any mailbox waiting for authorization keeps its place among the sidebar's mailboxes.
