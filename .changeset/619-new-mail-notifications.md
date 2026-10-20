---
'@private-email/mail-core': minor
'@private-email/localization': minor
'@private-email/mobile': minor
'@private-email/macos': minor
---

Notify privately for newly arrived Gmail Inbox mail on iPhone, iPad and Mac (#619). Settings › Notifications shows this device's notification permission, an off-by-default choice to show sender and subject, and a switch for each Gmail mailbox that synchronizes end-to-end encrypted to every Trusted Device. Only unread mail Gmail reports as newly added to the Inbox notifies, once, after it is saved; listings, backfill and moved mail never do. Tapping a notification opens its message.

Unreadable synchronized policies turn notifications off locally and cannot be overwritten. Refused changes show the latest learned policy and feedback on the mailbox's row; concurrent changes are handled without logging a registration failure.
