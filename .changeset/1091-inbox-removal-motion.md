---
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/mail-core': patch
---

Keep an Inbox row that an organizing action removes on screen while it collapses and fades, and grow it back from its current height on Undo or when a refused, rolled-back or discarded change returns it, in every window. A scroll, a selection or another action finishes a leaving row; synchronization never moves rows and keeps a scrolled list's topmost visible row in place (#1091).

Expose the shared organizing-row continuity projection through mail-core/mailboxes so both hosts use the same outcome and placement rules. Rows follow provider message IDs; an IMAP Inbox snapshot now names the ID each verified move started from (`originalIds`). Provider snapshots name the messages with unfinished changes (`organizing`), including an IMAP Undo still moving back, so a restored row stays the same row and a confirmed removal stays quiet even while another message has unfinished work.

Preserve Undo motion after a failed IMAP destination refresh and ignore a mobile exit completion delivered after the same row has started returning.
