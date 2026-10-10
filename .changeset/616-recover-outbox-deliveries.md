---
'@private-email/mail-core': minor
'@private-email/localization': patch
'@private-email/mobile': minor
'@private-email/macos': minor
---

Recover interrupted and uncertain Outbox deliveries. A message whose Gmail
handoff had no answer is looked up in Gmail's Sent mailbox by its MIME boundary
when it becomes unknown, when the app starts or becomes active, and on
**Check Again**; exactly one match records it as sent, and anything else keeps it
unknown without resending. **Edit** on an unknown message warns that Gmail may
already have sent it before returning it to the Drafts.

Sent checks also recover locked storage, device removal and refused Gmail access,
showing the authorization action even after an offline retry while keeping the
delivery outcome unknown.

A Sent check interrupted by a mailbox refresh resumes once the mailbox is ready,
including when readiness returns before the interrupted answer. Overlapping
**Check Again** requests share the running lookup.
