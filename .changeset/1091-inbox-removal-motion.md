---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/mail-core': patch
---

Keep an Inbox row that an organizing action removes on screen while it collapses and fades, and grow it back from its current height on Undo or when a refused, rolled-back or discarded change returns it, in every window. A scroll, a selection or another action finishes a leaving row; synchronization never moves rows and keeps a scrolled list's topmost visible row in place (#1091).

Expose the shared organizing-row continuity projection through mail-core/mailboxes so both hosts use the same outcome and placement rules.
