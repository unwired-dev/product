---
'@private-email/mobile': patch
'@private-email/localization': patch
'@private-email/mail-core': patch
---

Show the Sync Status Capsule above the iPhone and iPad Inbox bar: it counts
accounts still updating, measures All Mail's history download, and replaces
per-mailbox "could not be reached" notices with one attention summary and
Try Again for the unreachable mailboxes. A Gmail history download paused by a
failed read now reports `paused` and asks for Try Again instead of showing progress.
