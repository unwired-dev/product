---
'@private-email/macos': patch
'@private-email/localization': patch
---

Show the Sync Status Capsule above the Mac Inbox search bar: it counts accounts
still updating, measures All Mail's history download, and replaces per-mailbox
"could not be reached" notices with one attention summary and Try Again. Clicking
it opens a Sync Status popover listing each connection's state, history progress
and its own Try Again, with when the shown mailboxes were last updated. A new
View › Refresh (⌘R) menu command synchronizes the key window's Inbox.
