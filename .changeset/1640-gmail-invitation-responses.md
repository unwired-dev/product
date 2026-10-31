---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/macos': minor
---

Respond to a single Gmail meeting invitation from the Mac reader (#1640).

- **Card:** an opened Gmail message with a one-meeting `METHOD:REQUEST` calendar part shows the meeting above its body, with Accept, Maybe and Decline when it names the opened mailbox.
- **Sending:** a chosen response is one iCalendar REPLY to the organizer in the invitation's thread, sent only on request and never repeated on its own after an unknown delivery.
- **States:** sending, confirmed, refused, offline, sign-in, delivery unknown with Check Again and Respond Again…, another invited address, and invitations Unwired can't read.
