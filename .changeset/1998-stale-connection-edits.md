---
'@private-email/mail-core': patch
---

Turning New Mail Notifications on or off, choosing an IMAP connection's Spam and Trash folders, and moving a connection to another Mail Profile are now refused as `profile-changed` when another device has since removed the connection and added it again, so a device that has not synchronized yet can no longer overwrite the new connection's switch, folder choice or owner. The store reports them as `notificationFailure`, `foldersFailure` and `profileFailure` (#1998).
