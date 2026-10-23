---
'@private-email/mail-core': minor
'@private-email/mobile': minor
'@private-email/macos': minor
'@private-email/localization': patch
---

Move a mailbox between Mail Profiles and remove a Mail Profile from Settings ›
Mail Profiles on Mac, iPhone and iPad. Each mailbox of the selected Profile has a
system pop-up naming its Profile; Remove Mail Profile… asks first and, once
confirmed, also removes the Profile's mailboxes from every Trusted Device. The
registration store's `removeProfile` accepts the confirmed connections to remove
before the Profile, and refused moves and removals explain their reason.
