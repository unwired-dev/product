---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': minor
'@private-email/mail-core': minor
---

Rebuild the app shell around a Mailboxes sidebar and a floating search bar (#900).

- **Mailboxes:** a sidebar column lists **All inboxes** and its unread count, then each Mailbox Connection with its Inbox and unread count and, for IMAP, its selectable folders, and the **Account** page last. It replaces the mailbox and folder chips above the list. On the Mac it is a floating Liquid Glass column that a toolbar button hides and shows; windows at most 900pt wide start without it. On iPad it is the leading split-view column; on iPhone it is one Back away from the Inbox.
- **Floating bar:** search and **New Message** share a Liquid Glass bar at the bottom of the message list, which rows scroll under.

- **Mail core:** export the shared mailbox sidebar projection through `mail-core/mailboxes`, including unread totals, selectable folders, selection and authorization recovery.
